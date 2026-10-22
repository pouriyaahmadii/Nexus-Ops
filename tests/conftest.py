#!/usr/bin/env python3
"""
Pytest configuration and shared fixtures for NexusOps integration tests.
"""

import os
import asyncio
import pytest
import httpx
import docker
import time
import json
import random
import string
from typing import Dict, Any, Generator
from dataclasses import dataclass
from unittest.mock import AsyncMock, MagicMock

# Test configuration
COMPOSE_PROJECT_NAME = os.getenv("COMPOSE_PROJECT_NAME", "nexusops-test")
COMPOSE_FILE = os.getenv("COMPOSE_FILE", "compose.yaml")
BASE_URL = os.getenv("TEST_BASE_URL", "http://localhost")
N8N_URL = f"{BASE_URL}:5678"
WEBHOOK_URL = f"{BASE_URL}/webhook"
QDRANT_URL = f"{BASE_URL}:6333"
TRAEFIK_URL = BASE_URL


@dataclass
class TestConfig:
    """Test configuration."""
    compose_project: str = COMPOSE_PROJECT_NAME
    compose_file: str = COMPOSE_FILE
    base_url: str = BASE_URL
    n8n_url: str = N8N_URL
    webhook_url: str = WEBHOOK_URL
    qdrant_url: str = QDRANT_URL
    traefik_url: str = TRAEFIK_URL
    qdrant_api_key: str = os.getenv("QDRANT_API_KEY", "test-key")
    postgres_password: str = os.getenv("POSTGRES_PASSWORD", "test-pass")
    redis_password: str = os.getenv("REDIS_PASSWORD", "test-redis-pass")


@pytest.fixture(scope="session")
def config() -> TestConfig:
    """Global test configuration."""
    return TestConfig()


@pytest.fixture(scope="session")
def docker_client() -> Generator[docker.DockerClient, None, None]:
    """Docker client for container management."""
    client = docker.from_env()
    yield client
    client.close()


@pytest.fixture(scope="session")
def http_client() -> Generator[httpx.AsyncClient, None, None]:
    """Async HTTP client for API calls."""
    client = httpx.AsyncClient(timeout=30.0)
    yield client
    asyncio.get_event_loop().run_until_complete(client.aclose())


@pytest.fixture(scope="session")
def sync_http_client() -> Generator[httpx.Client, None, None]:
    """Sync HTTP client for API calls."""
    client = httpx.Client(timeout=30.0)
    yield client
    client.close()


# Wait-for utilities
async def wait_for_healthy(url: str, timeout: int = 180, interval: int = 5) -> bool:
    """Wait for a URL to return 200 OK."""
    start = time.time()
    async with httpx.AsyncClient(timeout=10.0) as client:
        while time.time() - start < timeout:
            try:
                resp = await client.get(url)
                if resp.status_code == 200:
                    return True
            except Exception:
                pass
            await asyncio.sleep(interval)
    return False


def wait_for_healthy_sync(url: str, timeout: int = 180, interval: int = 5) -> bool:
    """Sync version of wait_for_healthy."""
    start = time.time()
    with httpx.Client(timeout=10.0) as client:
        while time.time() - start < timeout:
            try:
                resp = client.get(url)
                if resp.status_code == 200:
                    return True
            except Exception:
                pass
            time.sleep(interval)
    return False


@pytest.fixture(scope="session", autouse=True)
def ensure_stack_healthy(config: TestConfig) -> Generator[None, None, None]:
    """Ensure the test stack is healthy before running tests."""
    # Check if stack is already running
    try:
        import docker
        client = docker.from_env()
        containers = client.containers.list(filters={"label": f"com.docker.compose.project={config.compose_project}"})
        if not containers:
            pytest.skip(f"Test stack '{config.compose_project}' not running. Start with: make up")
    except Exception:
        pytest.skip("Docker not available")
    
    # Wait for health
    if not wait_for_healthy_sync(f"{config.n8n_url}/healthz", timeout=180):
        pytest.skip("n8n not healthy")
    
    yield


# Test data generators
def random_string(length: int = 8) -> str:
    return ''.join(random.choices(string.ascii_lowercase + string.digits, k=length))


def random_email() -> str:
    return f"test_{random_string()}@example.com"


def random_correlation_id() -> str:
    return f"test_{int(time.time())}_{random_string(8)}"


# API clients
class N8NAPIClient:
    """Client for n8n REST API."""
    
    def __init__(self, base_url: str, api_key: str = ""):
        self.base_url = base_url.rstrip("/")
        self.api_key = api_key
        self.client = httpx.AsyncClient(timeout=30.0)
    
    async def __aenter__(self):
        return self
    
    async def __aexit__(self, *args):
        await self.client.aclose()
    
    def _headers(self) -> Dict[str, str]:
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["X-N8N-API-KEY"] = self.api_key
        return headers
    
    async def get_workflows(self) -> list:
        resp = await self.client.get(f"{self.base_url}/api/v1/workflows", headers=self._headers())
        resp.raise_for_status()
        return resp.json()
    
    async def execute_workflow(self, workflow_id: str, data: Dict = None) -> Dict:
        resp = await self.client.post(
            f"{self.base_url}/api/v1/workflows/{workflow_id}/execute",
            json=data or {},
            headers=self._headers()
        )
        resp.raise_for_status()
        return resp.json()
    
    async def get_executions(self, workflow_id: str = None) -> list:
        params = {"workflowId": workflow_id} if workflow_id else {}
        resp = await self.client.get(f"{self.base_url}/api/v1/executions", params=params, headers=self._headers())
        resp.raise_for_status()
        return resp.json()


class WebhookClient:
    """Client for webhook endpoints."""
    
    def __init__(self, base_url: str):
        self.base_url = base_url.rstrip("/")
        self.client = httpx.AsyncClient(timeout=30.0)
    
    async def __aenter__(self):
        return self
    
    async def __aexit__(self, *args):
        await self.client.aclose()
    
    async def post_triage(self, text: str, email: str = None, amount_usd: float = 0, correlation_id: str = None) -> httpx.Response:
        data = {
            "text": text,
            "email": email or random_email(),
            "amount_usd": amount_usd,
            "correlation_id": correlation_id or random_correlation_id()
        }
        return await self.client.post(f"{self.base_url}/webhook/triage", json=data)


# Database helpers
async def query_postgres(config: TestConfig, query: str, params: tuple = None) -> list:
    """Execute a query against the test Postgres database."""
    import asyncpg
    conn = await asyncpg.connect(
        host="localhost",
        port=5432,
        user="nexusops",
        password=config.postgres_password,
        database="nexusops"
    )
    try:
        if params:
            return await conn.fetch(query, *params)
        return await conn.fetch(query)
    finally:
        await conn.close()


# Mock Telegram server for testing
class MockTelegramServer:
    """Mock Telegram Bot API server for testing approvals and alerts."""
    
    def __init__(self, port: int = 8081):
        self.port = port
        self.messages = []
        self.callback_queries = []
        self._server = None
    
    async def start(self):
        from aiohttp import web
        app = web.Application()
        app.router.add_post("/bot{token}/sendMessage", self.handle_send_message)
        app.router.add_post("/bot{token}/answerCallbackQuery", self.handle_answer_callback)
        self._runner = web.AppRunner(app)
        await self._runner.setup()
        site = web.TCPSite(self._runner, "0.0.0.0", self.port)
        await site.start()
    
    async def stop(self):
        if self._runner:
            await self._runner.cleanup()
    
    async def handle_send_message(self, request):
        data = await request.post()
        self.messages.append(dict(data))
        return web.json_response({"ok": True, "result": {"message_id": len(self.messages)}})
    
    async def handle_answer_callback(self, request):
        data = await request.post()
        self.callback_queries.append(dict(data))
        return web.json_response({"ok": True})
    
    def get_last_message(self) -> Dict:
        return self.messages[-1] if self.messages else {}
    
    def clear(self):
        self.messages.clear()
        self.callback_queries.clear()


@pytest.fixture(scope="session")
def mock_telegram() -> Generator[MockTelegramServer, None, None]:
    """Mock Telegram server for testing."""
    server = MockTelegramServer()
    asyncio.get_event_loop().run_until_complete(server.start())
    yield server
    asyncio.get_event_loop().run_until_complete(server.stop())


# Test markers
def pytest_configure(config):
    config.addinivalue_line("markers", "smoke: quick smoke tests")
    config.addinivalue_line("markers", "integration: full integration tests")
    config.addinivalue_line("markers", "slow: slow tests")
    config.addinivalue_line("markers", "chaos: chaos engineering tests")
    config.addinivalue_line("markers", "approval: approval flow tests")
    config.addinivalue_line("markers", "cost: cost tracking tests")
    config.addinivalue_line("markers", "dlq: dead letter queue tests")
    config.addinivalue_line("markers", "retry: retry mechanism tests")