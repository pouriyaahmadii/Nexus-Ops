#!/usr/bin/env bash
# env-check.sh - Validate .env file has all required variables
# Usage: ./scripts/env-check.sh

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

REQUIRED_VARS=(
    "POSTGRES_PASSWORD"
    "REDIS_PASSWORD"
    "QDRANT_API_KEY"
    "N8N_ENCRYPTION_KEY"
    "OPS_WRITER_PASSWORD"
    "BACKUP_AGE_RECIPIENT"
)

OPTIONAL_VARS=(
    "ALERT_TELEGRAM_BOT_TOKEN"
    "ALERT_TELEGRAM_CHAT_ID"
    "LLM_MONTHLY_BUDGET_USD"
    "N8N_API_KEY"
    "N8N_PUBLIC_URL"
    "DEFAULT_APPROVER_PRIMARY"
    "DEFAULT_APPROVER_SECONDARY"
    "DLQ_REPLAY_TOKEN"
    "TRAEFIK_DASHBOARD_PASSWORD"
    "LE_EMAIL"
    "DOMAIN"
    "BACKUP_S3_ENDPOINT"
    "BACKUP_S3_BUCKET"
    "BACKUP_S3_ACCESS_KEY"
    "BACKUP_S3_SECRET_KEY"
    "BACKUP_HEARTBEAT_URL"
    "HEALTHCHECK_PING_URL"
    "N8N_BOOTSTRAP_PASSWORD"
    "GRAFANA_ADMIN_PASSWORD"
)

echo "=== NexusOps Environment Check ==="
echo ""

if [[ ! -f .env ]]; then
    echo -e "${RED}✗ .env file not found${NC}"
    echo "Run: cp .env.example .env"
    exit 1
fi

source .env

echo -e "${BLUE}Required variables:${NC}"
ALL_OK=true
for var in "${REQUIRED_VARS[@]}"; do
    if [[ -n "${!var:-}" ]]; then
        echo -e "  ${GREEN}✓${NC} $var"
    else
        echo -e "  ${RED}✗${NC} $var (MISSING)"
        ALL_OK=false
    fi
done

echo ""
echo -e "${BLUE}Optional variables:${NC}"
for var in "${OPTIONAL_VARS[@]}"; do
    if [[ -n "${!var:-}" ]]; then
        echo -e "  ${GREEN}✓${NC} $var"
    else
        echo -e "  ${YELLOW}○${NC} $var (not set)"
    fi
done

echo ""
if [[ "$ALL_OK" == "true" ]]; then
    echo -e "${GREEN}All required variables are set!${NC}"
    exit 0
else
    echo -e "${RED}Missing required variables. Please update .env${NC}"
    exit 1
fi