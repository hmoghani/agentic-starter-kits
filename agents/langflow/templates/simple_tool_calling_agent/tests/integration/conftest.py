from __future__ import annotations

import logging
import os

import pytest
from integration.conftest import cluster_auth, repo_root  # noqa: F401
from integration.utils import (
    RouteNotFoundError,
    get_route,
    load_agent_name,
    resolve_agent_dir,
)

logger = logging.getLogger(__name__)


def resolve_langflow_url(agent_name: str, namespace: str) -> str:
    """Return the Langflow agent URL from env override or route lookup."""
    override_url = os.environ.get("LANGFLOW_AGENT_URL", "").strip()
    if override_url:
        if not override_url.startswith("https://"):
            raise ValueError(f"LANGFLOW_AGENT_URL must use https://: {override_url}")
        return override_url.rstrip("/").removesuffix("/health_check")

    return get_route(agent_name, namespace=namespace)


@pytest.fixture(scope="module")
def agent_dir():
    return resolve_agent_dir(__file__)


@pytest.fixture(scope="module")
def agent_name(agent_dir):
    return load_agent_name(agent_dir)


@pytest.fixture(scope="module")
def deployed_agent(cluster_auth, agent_name):  # noqa: F811
    try:
        route_url = resolve_langflow_url(agent_name, cluster_auth["namespace"])
    except ValueError as exc:
        pytest.fail(str(exc))
    except RouteNotFoundError as exc:
        pytest.fail(
            f"Pre-deployed agent route not found: {exc}. "
            "Ensure the agent is deployed before running integration tests."
        )
    logger.info("Langflow agent at %s", route_url)
    yield route_url
