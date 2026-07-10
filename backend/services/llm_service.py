import re
import httpx
import logging
from typing import Dict, Any, List, Optional

logger = logging.getLogger(__name__)


class LLMUnavailableError(Exception):
    """Raised when the LLM can't be reached or the provider isn't available.
    Carries a user-friendly message meant to be shown directly in the UI."""


def _build_system_prompt(context: str, title: str, url: str, language: str | None = None) -> str:
    """Anchor every conversation to the specific bookmark being viewed, so the
    model always knows which page it is talking about — even on the first
    message and across follow-ups."""
    header = (
        "You are an assistant built into a bookmark manager. The user is "
        "currently viewing this one saved page, and every question is about it:\n"
    )
    if title:
        header += f"Title: {title}\n"
    if url:
        header += f"URL: {url}\n"
    header += (
        "\nUse the page content below to answer. If you are asked to summarize, "
        "summarize THIS page. If the content is a video transcript, treat it as "
        "what is spoken in the video. If the content does not contain the answer, "
        "say so instead of inventing details.\n\n"
        "Important limitation: you can read only the saved metadata and extracted "
        "page text. You cannot see the rendered page, screenshots, CSS, DOM layout, "
        "colors, images, or fonts unless they are explicitly present in the text. "
        "For design, UI, UX, color, typography, and layout questions, separate "
        "direct evidence from checks/recommendations, and do not guess visual "
        "details.\n\n"
        "--- PAGE CONTENT ---\n"
        f"{context}\n"
        "--- END PAGE CONTENT ---"
    )
    if language == "de":
        # Placed last (recency helps the model weight it) and kept independent
        # of whatever language the prompt/page content happens to be in — the
        # app's UI language decides the reply language, not a guess.
        header += (
            "\n\nWICHTIG: Antworte auf Deutsch, unabhängig davon, in welcher "
            "Sprache die Frage oder der Seiteninhalt verfasst sind."
        )
    return header


_shared_client: httpx.AsyncClient | None = None


def _get_client() -> httpx.AsyncClient:
    global _shared_client
    if _shared_client is None or _shared_client.is_closed:
        _shared_client = httpx.AsyncClient(timeout=120.0)
    return _shared_client


class LLMService:
    @staticmethod
    async def ask_llm(
        prompt: str,
        context: str,
        provider_config: Dict[str, Any],
        title: str = "",
        url: str = "",
        history: Optional[List[Dict[str, str]]] = None,
        think: Optional[bool] = None,
        options: Optional[Dict[str, Any]] = None,
        language: str | None = None,
    ) -> str:
        """
        Orchestrate the request to the LLM based on provider configuration.

        ``think`` and ``options`` are forwarded to Ollama. Set ``think=False`` for
        short, mechanical tasks (e.g. tagging) so reasoning models like qwen3 skip
        their <think> phase — that alone is a ~40x speedup per call.

        ``language`` ("de"/None) is the app's UI language — it steers the reply
        language via the system prompt, independent of what language the user's
        question or the page content happens to be in.
        """
        provider = provider_config.get("provider", "ollama")
        history = history or []

        if provider == "ollama":
            return await LLMService._ask_ollama(prompt, context, provider_config, title, url, history, think, options, language)
        # Gyrus is local-only by design — there is no cloud provider. This guards
        # against an unexpected/legacy provider value in a stored config.
        raise LLMUnavailableError(
            "Gyrus uses a local model. Configure Ollama in Settings → AI to "
            "chat with the Brain."
        )

    @staticmethod
    def _build_messages(prompt, context, title, url, history, language: str | None = None) -> List[Dict[str, str]]:
        messages: List[Dict[str, str]] = [
            {"role": "system", "content": _build_system_prompt(context, title, url, language)}
        ]
        for turn in (history or []):
            role = turn.get("role")
            content = turn.get("content", "")
            if role in ("user", "assistant") and content:
                messages.append({"role": role, "content": content})
        messages.append({"role": "user", "content": prompt})
        return messages

    @staticmethod
    def _ollama_base(provider_config: Dict[str, Any]) -> str:
        return (provider_config.get("base_url")
                or provider_config.get("ollama_url")
                or "http://localhost:11434")

    @staticmethod
    async def _ask_ollama(
        prompt: str,
        context: str,
        provider_config: Dict[str, Any],
        title: str,
        url: str,
        history: List[Dict[str, str]],
        think: Optional[bool] = None,
        options: Optional[Dict[str, Any]] = None,
        language: str | None = None,
    ) -> str:
        """
        Send a chat request to a local Ollama instance, using role-based
        messages so the page context and prior turns are always present.
        """
        base_url = LLMService._ollama_base(provider_config)
        model = provider_config.get("model", "llama3")
        messages = LLMService._build_messages(prompt, context, title, url, history, language)
        payload: Dict[str, Any] = {"model": model, "messages": messages, "stream": False}
        # think=False makes reasoning models (qwen3, deepseek-r1) skip their
        # <think> phase; it is a harmless no-op on plain models. Safe to always send.
        if think is not None:
            payload["think"] = think
        if options:
            payload["options"] = options

        client = _get_client()
        try:
            response = await client.post(f"{base_url}/api/chat", json=payload)
            if response.status_code == 400 and "think" in payload:
                # Some models / older Ollama versions reject the `think` field.
                # Drop it and retry once so tagging still works on those models.
                payload.pop("think", None)
                response = await client.post(f"{base_url}/api/chat", json=payload)
            response.raise_for_status()
            data = response.json()
            content = data.get("message", {}).get("content", "") or ""
            # Strip any reasoning block, in case a model emits <think>…</think>
            # inline despite think=False.
            return re.sub(r"<think>.*?</think>", "", content, flags=re.DOTALL).strip()
        except httpx.ConnectError:
            raise LLMUnavailableError(
                "Couldn't reach Ollama. Make sure it's running "
                f"(at {base_url}) and the model is installed."
            )
        except httpx.HTTPStatusError as e:
            if e.response is not None and e.response.status_code == 404:
                raise LLMUnavailableError(
                    f"Model '{model}' isn't installed in Ollama. "
                    f"Run: ollama pull {model}"
                )
            raise LLMUnavailableError(f"Ollama returned an error: {e}")

    @staticmethod
    async def stream_ollama(
        prompt: str,
        context: str,
        provider_config: Dict[str, Any],
        title: str = "",
        url: str = "",
        history: Optional[List[Dict[str, str]]] = None,
        language: str | None = None,
    ):
        """Yield the assistant reply token-by-token as it is generated, so the
        UI can render it live instead of waiting for the whole answer."""
        import json as _json

        base_url = LLMService._ollama_base(provider_config)
        model = provider_config.get("model", "llama3")
        messages = LLMService._build_messages(prompt, context, title, url, history, language)
        payload = {"model": model, "messages": messages, "stream": True}

        client = _get_client()
        try:
            async with client.stream("POST", f"{base_url}/api/chat", json=payload) as resp:
                if resp.status_code >= 400:
                    # Map errors to the same friendly messages as the non-stream
                    # path. Must read the body first in streaming mode.
                    await resp.aread()
                    if resp.status_code == 404:
                        raise LLMUnavailableError(
                            f"Model '{model}' isn't installed in Ollama. "
                            f"Run: ollama pull {model}"
                        )
                    raise LLMUnavailableError(
                        f"Ollama returned an error (HTTP {resp.status_code})."
                    )
                async for line in resp.aiter_lines():
                    if not line.strip():
                        continue
                    try:
                        chunk = _json.loads(line)
                    except Exception:
                        continue
                    piece = chunk.get("message", {}).get("content", "")
                    if piece:
                        yield piece
                    if chunk.get("done"):
                        break
        except httpx.ConnectError:
            raise LLMUnavailableError(
                "Couldn't reach Ollama. Make sure it's running "
                f"(at {base_url}) and the model is installed."
            )
