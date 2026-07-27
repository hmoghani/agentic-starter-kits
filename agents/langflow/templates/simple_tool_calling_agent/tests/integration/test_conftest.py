from __future__ import annotations

import pytest
from conftest import resolve_langflow_url


class TestResolveLangflowUrl:
    """Verify LANGFLOW_AGENT_URL override, validation, and fallback."""

    def test_uses_override_when_set(self, monkeypatch):
        monkeypatch.setenv("LANGFLOW_AGENT_URL", "https://langflow.example.com")
        url = resolve_langflow_url("ignored", "ci-testing")
        assert url == "https://langflow.example.com"

    def test_strips_trailing_slash(self, monkeypatch):
        monkeypatch.setenv("LANGFLOW_AGENT_URL", "https://langflow.example.com/")
        url = resolve_langflow_url("ignored", "ci-testing")
        assert url == "https://langflow.example.com"

    def test_strips_trailing_health_check(self, monkeypatch):
        monkeypatch.setenv(
            "LANGFLOW_AGENT_URL", "https://langflow.example.com/health_check"
        )
        url = resolve_langflow_url("ignored", "ci-testing")
        assert url == "https://langflow.example.com"

    def test_rejects_http_scheme(self, monkeypatch):
        monkeypatch.setenv("LANGFLOW_AGENT_URL", "http://langflow.example.com")
        with pytest.raises(ValueError, match="must use https://"):
            resolve_langflow_url("ignored", "ci-testing")

    def test_falls_back_to_get_route(self, monkeypatch):
        monkeypatch.delenv("LANGFLOW_AGENT_URL", raising=False)
        monkeypatch.setattr(
            "conftest.get_route",
            lambda name, namespace: f"https://{name}.apps.example.com",
        )
        url = resolve_langflow_url("my-agent", "ci-testing")
        assert url == "https://my-agent.apps.example.com"

    def test_empty_var_falls_back_to_get_route(self, monkeypatch):
        monkeypatch.setenv("LANGFLOW_AGENT_URL", "  ")
        monkeypatch.setattr(
            "conftest.get_route",
            lambda name, namespace: f"https://{name}.apps.example.com",
        )
        url = resolve_langflow_url("my-agent", "ci-testing")
        assert url == "https://my-agent.apps.example.com"
