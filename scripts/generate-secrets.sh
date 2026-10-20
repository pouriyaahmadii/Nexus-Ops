#!/usr/bin/env bash
# ==============================================================================
# NexusOps - Secret Generation Script
# Generates cryptographic secrets and populates .env securely with 0600 permissions.
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
ENV_FILE="${ROOT_DIR}/.env"

generate_random_secret() {
  local length="${1:-32}"
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$((length / 2))"
  else
    LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${length}" || true
  fi
}

echo "==> Validating NexusOps environment configuration..."

# Generate fresh secrets
N8N_KEY="$(generate_random_secret 32)"
PG_PASS="$(generate_random_secret 24)"
REDIS_PASS="$(generate_random_secret 24)"
QDRANT_KEY="$(generate_random_secret 32)"

if [[ -f "${ENV_FILE}" ]]; then
  echo "Found existing .env file at ${ENV_FILE}."
  # Check for required variables and append if missing
  REQUIRED_VARS=("COMPOSE_PROJECT_NAME" "N8N_ENCRYPTION_KEY" "POSTGRES_PASSWORD" "REDIS_PASSWORD" "QDRANT_API_KEY")
  for var in "${REQUIRED_VARS[@]}"; do
    if ! grep -q "^${var}=" "${ENV_FILE}"; then
      echo "Appending missing variable ${var} to .env..."
      case "${var}" in
        COMPOSE_PROJECT_NAME)
          echo "COMPOSE_PROJECT_NAME=nexusops" >> "${ENV_FILE}"
          ;;
        N8N_ENCRYPTION_KEY)
          echo "N8N_ENCRYPTION_KEY=${N8N_KEY}" >> "${ENV_FILE}"
          ;;
        POSTGRES_PASSWORD)
          echo "POSTGRES_PASSWORD=${PG_PASS}" >> "${ENV_FILE}"
          ;;
        REDIS_PASSWORD)
          echo "REDIS_PASSWORD=${REDIS_PASS}" >> "${ENV_FILE}"
          ;;
        QDRANT_API_KEY)
          echo "QDRANT_API_KEY=${QDRANT_KEY}" >> "${ENV_FILE}"
          ;;
      esac
    fi
  done
else
  echo "==> Creating new .env file with generated secrets..."
  cat <<EOF > "${ENV_FILE}"
# ==============================================================================
# NexusOps - Environment Configuration
# Generated automatically by scripts/generate-secrets.sh
# ==============================================================================
COMPOSE_PROJECT_NAME=nexusops

# Ingress & Networking (Avoid privileged / host port conflicts)
DOMAIN_NAME=nexusops.localhost
TRAEFIK_HTTP_PORT=8080
TRAEFIK_HTTPS_PORT=8443
QDRANT_PORT=6333

# Database (PostgreSQL 16) - Strictly Internal Docker Network
POSTGRES_USER=nexusops
POSTGRES_PASSWORD=${PG_PASS}
POSTGRES_DB=nexusops

# Cache & Queue (Redis 7) - Strictly Internal Docker Network
REDIS_PASSWORD=${REDIS_PASS}

# Vector Database (Qdrant)
QDRANT_API_KEY=${QDRANT_KEY}

# Automation Engine (n8n Queue Mode)
N8N_ENCRYPTION_KEY=${N8N_KEY}
N8N_HOST=nexusops.localhost
N8N_PORT=5678
N8N_PROTOCOL=http
WEBHOOK_URL=http://nexusops.localhost:8080/
N8N_DIAGNOSTICS_ENABLED=false
N8N_PERSONALIZATION_ENABLED=false
EOF
fi

chmod 600 "${ENV_FILE}"
echo "==> .env configured successfully at ${ENV_FILE} (permissions 0600)."
