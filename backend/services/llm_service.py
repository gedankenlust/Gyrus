import httpx
import logging
from typing import Dict, Any, List, Optional

logger = logging.getLogger(__name__)


def _build_system_prompt(context: str, title: str, url: str) -> str:
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
        "--- PAGE CONTENT ---\n"
        f"{context}\n"
        "--- END PAGE CONTENT ---"
    )
    return header


class LLMService:
    @staticmethod
    async def ask_llm(
        prompt: str,
        context: str,
        provider_config: Dict[str, Any],
        title: str = "",
        url: str = "",
        history: Optional[List[Dict[str, str]]] = None,
    ) -> str:
        """
        Orchestrate the request to the LLM based on provider configuration.
        """
        provider = provider_config.get("provider", "ollama")
        history = history or []

        if provider == "ollama":
            return await LLMService._ask_ollama(prompt, context, provider_config, title, url, history)
        elif provider in ["cloud", "openai", "anthropic", "google"]:
            return await LLMService._ask_cloud(prompt, context, provider_config)
        else:
            # Fallback to cloud stub instead of raising ValueError for robustness
            logger.warning(f"Unsupported LLM provider '{provider}', falling back to Cloud stub.")
            return await LLMService._ask_cloud(prompt, context, provider_config)

    @staticmethod
    async def _ask_ollama(
        prompt: str,
        context: str,
        provider_config: Dict[str, Any],
        title: str,
        url: str,
        history: List[Dict[str, str]],
    ) -> str:
        """
        Send a chat request to a local Ollama instance, using role-based
        messages so the page context and prior turns are always present.
        """
        base_url = provider_config.get("base_url") or provider_config.get("ollama_url") or "http://localhost:11434"
        model = provider_config.get("model", "llama3")

        messages: List[Dict[str, str]] = [
            {"role": "system", "content": _build_system_prompt(context, title, url)}
        ]
        for turn in history:
            role = turn.get("role")
            content = turn.get("content", "")
            if role in ("user", "assistant") and content:
                messages.append({"role": role, "content": content})
        messages.append({"role": "user", "content": prompt})

        payload = {"model": model, "messages": messages, "stream": False}

        async with httpx.AsyncClient(timeout=120.0) as client:
            response = await client.post(f"{base_url}/api/chat", json=payload)
            response.raise_for_status()
            data = response.json()
            return data.get("message", {}).get("content", "")

    @staticmethod
    async def _ask_cloud(prompt: str, context: str, provider_config: Dict[str, Any]) -> str:
        """
        Placeholder for Cloud providers (OpenAI/Anthropic).
        In a real implementation, this would use API keys and appropriate endpoints.
        """
        cloud_provider = provider_config.get("cloud_provider") or provider_config.get("provider") or "cloud"
        model = provider_config.get("model", "gpt-3.5-turbo")

        # This is a stub that simulates a cloud request
        logger.info(f"Simulating {cloud_provider} request with model {model}")

        # For now, we'll return a message indicating it's a stub,
        # but structured to be easily replaced by actual httpx calls.
        return f"[Cloud Provider Stub: {cloud_provider}] I've processed your question based on the context provided. (Model: {model})"
