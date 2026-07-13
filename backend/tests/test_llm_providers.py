import pytest
from unittest.mock import patch, MagicMock, AsyncMock
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

    with patch("services.llm_service._get_client") as mock_get:
        mock_client = AsyncMock()
        mock_client.post.side_effect = boom
        mock_get.return_value = mock_client
        with pytest.raises(LLMUnavailableError) as exc:
            await LLMService.ask_llm("Hi", "Context", provider_config)
        assert "Ollama" in str(exc.value)


@pytest.mark.asyncio
async def test_unload_ollama_models_releases_every_loaded_model():
    released = []

    class Response:
        def __init__(self, payload=None):
            self.payload = payload or {}

        def raise_for_status(self):
            return None

        def json(self):
            return self.payload

    class Client:
        async def __aenter__(self):
            return self

        async def __aexit__(self, *args):
            return None

        async def get(self, url):
            return Response({"models": [{"model": "qwen3:8b"}, {"name": "bge-m3:latest"}]})

        async def post(self, url, json):
            released.append(json)
            return Response()

    with patch("services.llm_service.httpx.AsyncClient", return_value=Client()):
        await LLMService.unload_ollama_models("http://ollama.test")

    assert released == [
        {"model": "qwen3:8b", "keep_alive": 0},
        {"model": "bge-m3:latest", "keep_alive": 0},
    ]
