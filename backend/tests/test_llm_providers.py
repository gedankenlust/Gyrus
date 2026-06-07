import pytest
from unittest.mock import patch, MagicMock
from services.llm_service import LLMService

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
async def test_ask_llm_cloud_openai():
    provider_config = {
        "provider": "cloud",
        "cloud_provider": "openai",
        "model": "gpt-4"
    }
    
    # Since _ask_cloud is currently a stub, we can test it directly or mock it
    response = await LLMService.ask_llm("Hi", "Context", provider_config)
    assert "[Cloud Provider Stub: openai]" in response
    assert "gpt-4" in response

@pytest.mark.asyncio
async def test_ask_llm_cloud_anthropic():
    provider_config = {
        "provider": "cloud",
        "cloud_provider": "anthropic",
        "model": "claude-3"
    }
    
    response = await LLMService.ask_llm("Hi", "Context", provider_config)
    assert "[Cloud Provider Stub: anthropic]" in response
    assert "claude-3" in response

@pytest.mark.asyncio
async def test_ask_llm_direct_openai():
    # Test passing 'openai' directly as provider
    provider_config = {
        "provider": "openai",
        "model": "gpt-3.5-turbo"
    }
    
    response = await LLMService.ask_llm("Hi", "Context", provider_config)
    assert "[Cloud Provider Stub: openai]" in response
    assert "gpt-3.5-turbo" in response

@pytest.mark.asyncio
async def test_ask_llm_unsupported():
    provider_config = {
        "provider": "invalid"
    }
    
    # Now it should fallback to cloud stub instead of raising ValueError
    response = await LLMService.ask_llm("Hi", "Context", provider_config)
    assert "[Cloud Provider Stub:" in response
    assert "invalid" in response
