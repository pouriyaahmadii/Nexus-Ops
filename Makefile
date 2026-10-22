# ==============================================================================
# AutoForge / NexusOps - Automation Platform Makefile
# ==============================================================================
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

COMPOSE_PROJECT_NAME ?= nexusops

.PHONY: help up down logs doctor backup backup-list restore restore-test demo lint scale workers
COMPOSE_FILE ?= compose.yaml

help: ## Print this formatted list of targets with descriptions
	@echo "NexusOps Management CLI"
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

up: ## Start the platform services (base: docker compose up -d)
	@docker compose -p $(COMPOSE_PROJECT_NAME) -f $(COMPOSE_FILE) up -d

down: ## Stop and remove all platform containers
	@docker compose -p $(COMPOSE_PROJECT_NAME) -f $(COMPOSE_FILE) down

logs: ## Follow logs from running platform services
	@docker compose -p $(COMPOSE_PROJECT_NAME) -f $(COMPOSE_FILE) logs -f

doctor: ## Run diagnostic checks on system requirements and ports (Phase 10)
	@echo "[doctor] Placeholder: Host diagnostics and port checks will be introduced in Phase 10."

backup: ## Trigger encrypted backup (Postgres, Qdrant, n8n data, Traefik acme)
	@docker compose -p $(COMPOSE_PROJECT_NAME) -f $(COMPOSE_FILE) run --rm backup /scripts/backup.sh

backup-list: ## List available backups
	@docker run --rm -v nexusops_backups:/backup/data:ro alpine:3.21 \
		sh -c 'find /backup/data -maxdepth 1 -type d -name "nexusops-*" | sort -r | head -20'

restore: ## Restore from backup (usage: make restore SNAPSHOT=nexusops-...)
	@if [ -z "$(SNAPSHOT)" ]; then echo "Usage: make restore SNAPSHOT=nexusops-..."; exit 1; fi
	@docker compose -p $(COMPOSE_PROJECT_NAME) -f $(COMPOSE_FILE) run --rm backup /scripts/restore.sh --yes $(SNAPSHOT)

restore-test: ## Run automated restore drill in isolated environment
	@docker run --rm \
	    --name $(COMPOSE_PROJECT_NAME)-restore-test \
	    -v /var/run/docker.sock:/var/run/docker.sock:ro \
	    -v nexusops_backups:/backup/data:ro \
	    -v nexusops_n8n_data:/n8n/data:ro \
	    -v nexusops_letsencrypt:/traefik:ro \
	    -e BACKUP_DIR=/backup/data \
	    -e BACKUP_AGE_RECIPIENT="$(BACKUP_AGE_RECIPIENT)" \
	    -e POSTGRES_PASSWORD="$(POSTGRES_PASSWORD)" \
	    -e REDIS_PASSWORD="$(REDIS_PASSWORD)" \
	    -e QDRANT_API_KEY="$(QDRANT_API_KEY)" \
	    -e N8N_ENCRYPTION_KEY="$(N8N_ENCRYPTION_KEY)" \
	    -e BACKUP_S3_ENABLED="$(BACKUP_S3_ENABLED)" \
	    -e BACKUP_S3_ENDPOINT="$(BACKUP_S3_ENDPOINT)" \
	    -e BACKUP_S3_BUCKET="$(BACKUP_S3_BUCKET)" \
	    -e BACKUP_S3_PREFIX="$(BACKUP_S3_PREFIX)" \
	    -e BACKUP_S3_ACCESS_KEY="$(BACKUP_S3_ACCESS_KEY)" \
	    -e BACKUP_S3_SECRET_KEY="$(BACKUP_S3_SECRET_KEY)" \
	    nexusops-backup:latest /scripts/restore-test.sh

demo: ## Run end-to-end showcase workflow in mock mode (Phase 9)
	@DEMO_MODE=mock bash scripts/demo.sh run

lint: ## Run syntax and lint checks across repository files
	@echo "==> Running syntax and hygiene checks..."
	@if command -v pre-commit >/dev/null 2>&1; then \
		pre-commit run --all-files; \
	else \
		echo "pre-commit is not installed locally. Run: pip install pre-commit"; \
	fi

scale: ## Scale n8n workers (usage: make scale WORKERS=N)
	@if [ -z "${WORKERS}" ]; then echo "Usage: make scale WORKERS=N"; exit 1; fi
	@docker compose -p $(COMPOSE_PROJECT_NAME) -f $(COMPOSE_FILE) up -d --scale n8n-worker=${WORKERS} --no-recreate

workers: ## Show n8n worker status
	@docker compose -p $(COMPOSE_PROJECT_NAME) -f $(COMPOSE_FILE) ps n8n-worker
