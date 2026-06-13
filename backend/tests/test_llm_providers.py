import pytest
from unittest.mock import patch, MagicMock
from services.llm_service import LLMService, LLMUnavailableError


@pytest.mark.asyncio
async def test_ask_llm_ollama():
    provider_config = {
        "provider": "ollama",
        "model": "llama3",
        "base_url": "http://localhost:11434"
    }

    async def async_return(val): return val

    with patch("services.llm_service.LLMService._ask_ollama", new_callable=MagicMock) as mock_ollama:
        mock_ollama.side_effect = lambda *args, **kwargs: async_return("Ollama response")

        response = await LLMService.ask_llm("Hi", "Context", provider_config)
        assert response == "Ollama response"
        mock_ollama.assert_called_once()


@pytest.mark.asyncio
async def test_cloud_provider_raises_clear_error():
    # Gyrus is local-only by design — any non-ollama provider (e.g. a legacy
    # "cloud" value in a stored config) must raise a clear, user-facing error
    # instead of returning a fake stub answer.
    for provider in ("cloud", "openai", "anthropic", "google"):
        with pytest.raises(LLMUnavailableError) as exc:
            await LLMService.ask_llm("Hi", "Context", {"provider": provider})
        assert "Ollama" in str(exc.value)


@pytest.mark.asyncio
async def test_unsupported_provider_raises():
    with pytest.raises(LLMUnavailableError):
        await LLMService.ask_llm("Hi", "Context", {"provider": "invalid"})


@pytest.mark.asyncio
async def test_ollama_connection_error_is_friendly():
    import httpx
    provider_config = {"provider": "ollama", "model": "llama3",
                       "base_url": "http://localhost:11434"}

    async def boom(*a, **k):
        raise httpx.ConnectError("refused")

    with patch("services.llm_service.httpx.AsyncClient") as mock_client:
        instance = mock_client.return_value.__aenter__.return_value
        instance.post.side_effect = boom
        with pytest.raises(LLMUnavailableError) as exc:
            await LLMService.ask_llm("Hi", "Context", provider_config)
        assert "Ollama" in str(exc.value)
