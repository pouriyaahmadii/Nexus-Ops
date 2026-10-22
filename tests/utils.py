#!/usr/bin/env python3
"""
Test utilities for NexusOps integration tests.
"""

import asyncio
import httpx
import docker
import time
import random
import string
from typing import Dict, Any, Optional, List
from dataclasses import dataclass, field


@dataclass
class ServiceEndpoint:
    """Service endpoint configuration."""
    name: str
    url: str
    health_path: str = "/healthz"
    expected_status: int = 200


# Default service endpoints for smoke tests
DEFAULT_ENDPOINTS = [
    ServiceEndpoint("n8n-main", "http://localhost:5678", "/healthz"),
    ServiceEndpoint("traefik", "http://localhost", "/"),
    ServiceEndpoint("qdrant", "http://localhost:6333", "/healthz"),
    ServiceEndpoint("traefik-dashboard", "http://localhost:8080", "/"),
]


@dataclass
class TestResult:
    """Result of a test check."""
    name: str
    passed: bool
    message: str = ""
    duration_ms: float = 0.0


class WaitFor:
    """Utilities for waiting on conditions."""
    
    @staticmethod
    async def healthy(url: str, timeout: int = 180, interval: int = 5) -> bool:
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
    
    @staticmethod
    def healthy_sync(url: str, timeout: int = 180, interval: int = 5) -> bool:
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
    
    @staticmethod
    async def stack_healthy(project_name: str, compose_file: str, timeout: int = 300) -> bool:
        """Wait for all Docker Compose services to be healthy."""
        import subprocess
        start = time.time()
        while time.time() - start < timeout:
            try:
                result = subprocess.run([
                    "docker", "compose", "-p", project_name, "-f", compose_file,
                    "ps", "--format", "json"
                ], capture_output=True, text=True, timeout=10)
                if result.returncode == 0:
                    import json
                    services = json.loads(result.stdout) if result.stdout.strip() else []
                    if services and all(s.get("Health") in ("healthy", "") for s in services):
                        return True
            except Exception:
                pass
            await asyncio.sleep(5)
        return False


class N8NClient:
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
    
    async def get_workflows(self) -> List[Dict]:
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
    
    async def get_executions(self, workflow_id: str = None, limit: int = 50) -> List[Dict]:
        params = {"limit": limit}
        if workflow_id:
            params["workflowId"] = workflow_id
        resp = await self.client.get(
            f"{self.base_url}/api/v1/executions",
            params=params,
            headers=self._headers()
        )
        resp.raise_for_status()
        return resp.json()
    
    async def get_execution(self, execution_id: str) -> Dict:
        resp = await self.client.get(
            f"{self.base_url}/api/v1/executions/{execution_id}",
            headers=self._headers()
        )
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
    
    async def post_triage(
        self,
        text: str,
        email: str = None,
        amount_usd: float = 0,
        correlation_id: str = None
    ) -> httpx.Response:
        data = {
            "text": text,
            "email": email or f"test_{random_string()}@example.com",
            "amount_usd": amount_usd,
            "correlation_id": correlation_id or f"test_{int(time.time())}_{random_string(8)}"
        }
        return await self.client.post(f"{self.base_url}/webhook/triage", json=data)


def random_string(length: int = 8) -> str:
    return ''.join(random.choices(string.ascii_lowercase + string.digits, k=length))


def random_email() -> str:
    return f"test_{random_string()}@example.com"


def random_correlation_id() -> str:
    return f"test_{int(time.time())}_{random_string(8)}"


class DockerHelper:
    """Helper for Docker operations."""
    
    def __init__(self, project_name: str = "nexusops"):
        self.project_name = project_name
        self.client = docker.from_env()
    
    def get_containers(self) -> List[docker.models.containers.Container]:
        return self.client.containers.list(
            filters={"label": f"com.docker.compose.project={self.project_name}"}
        )
    
    def get_service_health(self, service_name: str) -> Optional[str]:
        """Get health status of a service."""
        containers = self.client.containers.list(
            filters={
                "label": [
                    f"com.docker.compose.project={self.project_name}",
                    f"com.docker.compose.service={service_name}"
                ]
            }
        )
        if not containers:
            return None
        # Return health of first container
        container = containers[0]
        health = container.attrs.get("State", {}).get("Health", {})
        return health.get("Status")
    
    def all_healthy(self) -> bool:
        """Check if all project containers are healthy."""
        for container in self.get_containers():
            health = container.attrs.get("State", {}).get("Health", {})
            status = health.get("Status")
            if status not in ("healthy", None, ""):
                return False
        return True
    
    def wait_healthy(self, timeout: int = 300, interval: int = 5) -> bool:
        """Wait for all containers to be healthy."""
        start = time.time()
        while time.time() - start < timeout:
            if self.all_healthy():
                return True
            time.sleep(interval)
        return False
    
    def logs(self, service: str, tail: int = 100) -> str:
        """Get logs for a service."""
        containers = self.client.containers.list(
            filters={
                "label": [
                    f"com.docker.compose.project={self.project_name}",
                    f"com.docker.compose.service={service}"
                ]
            }
        )
        if not containers:
            return ""
        return containers[0].logs(tail=tail).decode("utf-8", errors="replace")
    
    def exec(self, service: str, cmd: List[str]) -> tuple:
        """Execute command in a service container."""
        containers = self.client.containers.list(
            filters={
                "label": [
                    f"com.docker.compose.project={self.project_name}",
                    f"com.docker.compose.service={service}"
                ]
            }
        )
        if not containers:
            return (1, "", "Container not found")
        result = containers[0].exec_run(cmd)
        return (result.exit_code, result.output.decode("utf-8", errors="replace") if result.output else "", "")


# Decorators for test categorization
def smoke_test(func):
    """Mark test as smoke test."""
    import pytest
    return pytest.mark.smoke(func)


def integration_test(func):
    """Mark test as integration test."""
    import pytest
    return pytest.mark.integration(func)


def slow_test(func):
    """Mark test as slow."""
    import pytest
    return pytest.mark.slow(func)


def chaos_test(func):
    """Mark test as chaos engineering test."""
    import pytest
    return pytest.mark.chaos(func)


def approval_test(func):
    """Mark test as approval flow test."""
    import pytest
    return pytest.mark.approval(func)


def cost_test(func):
    """Mark test as cost tracking test."""
    import pytest
    return pytest.mark.cost(func)


def dlq_test(func):
    """Mark test as dead letter queue test."""
    import pytest
    return pytest.mark.dlq(func)


def retry_test(func):
    """Mark test as retry mechanism test."""
    import pytest
    return pytest.mark.retry(func)


def queue_test(func):
    """Mark test as queue mode test."""
    import pytest
    return pytest.mark.queue(func)