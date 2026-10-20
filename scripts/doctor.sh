#!/usr/bin/env bash
# ==============================================================================
# NexusOps - Environment & Port Diagnostic Tool (doctor.sh)
# Checks Docker daemon, port isolation, reserved ports, and configuration.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

echo "==> Running NexusOps Environment Diagnostics..."

# 1. Docker Daemon Check
if ! docker info >/dev/null 2>&1; then
  echo "[FAIL] Docker daemon is not reachable. Ensure Docker Desktop is started."
  exit 1
else
  echo "[PASS] Docker daemon is running and responsive."
fi

# 2. Namespace & Compose Project
PROJECT_NAME="nexusops"
echo "[PASS] Compose namespace enforced: ${PROJECT_NAME}"

# 3. Port Isolation & Reserved Host Ports
RESERVED_PORTS=(3000 8000 5432 6379 5678)
NEXUS_PORTS=(8080 8443 6333)

echo "--> Checking Reserved External Ports (AgentOps isolation)..."
for port in "${RESERVED_PORTS[@]}"; do
  if lsof -iTCP:"${port}" -sTCP:LISTEN -n -P >/dev/null 2>&1; then
    echo "    [INFO] Reserved port ${port} is active on host (Isolated from NexusOps)."
  else
    echo "    [OK] Reserved port ${port} is free or unexposed."
  fi
done

echo "--> Checking NexusOps Ingress & Service Ports..."
COLLISION=0
for port in "${NEXUS_PORTS[@]}"; do
  # Check if port is held by a non-nexusops process
  if lsof -iTCP:"${port}" -sTCP:LISTEN -n -P >/dev/null 2>&1; then
    HOLDER="$(lsof -iTCP:"${port}" -sTCP:LISTEN -n -P | tail -n +2 | head -n 1 | awk '{print $1, $2}')"
    echo "    [WARN] Port ${port} is currently bound by: ${HOLDER}"
  else
    echo "    [PASS] Port ${port} is available."
  fi
done

# 4. Verify .env and Secrets
if [[ ! -f "${ROOT_DIR}/.env" ]]; then
  echo "[FAIL] .env file missing. Run ./scripts/generate-secrets.sh to initialize."
  exit 1
fi

REQUIRED_KEYS=("COMPOSE_PROJECT_NAME" "N8N_ENCRYPTION_KEY" "POSTGRES_PASSWORD" "REDIS_PASSWORD" "QDRANT_API_KEY")
for key in "${REQUIRED_KEYS[@]}"; do
  if ! grep -q "^${key}=" "${ROOT_DIR}/.env"; then
    echo "[FAIL] Missing required key in .env: ${key}"
    exit 1
  fi
done
echo "[PASS] All required keys found in .env."

# 5. Validate Compose Specification
if docker compose -p "${PROJECT_NAME}" -f "${ROOT_DIR}/compose.yaml" config -q; then
  echo "[PASS] docker compose config -q passed without errors."
else
  echo "[FAIL] docker compose configuration validation failed."
  exit 1
fi

echo "==> All NexusOps diagnostic checks completed successfully."
