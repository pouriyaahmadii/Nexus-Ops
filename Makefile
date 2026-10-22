# ==============================================================================
# AutoForge / NexusOps - Automation Platform Makefile
# ==============================================================================
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

COMPOSE_PROJECT_NAME ?= nexusops
COMPOSE_FILE ?= compose.yaml

.PHONY: help up down restart logs ps doctor backup backup-list restore restore-test demo upgrade rollback lint scale workers env-check clean test test-fast test-smoke test-integration test-sql test-restore

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

restart: ## Restart all platform services
	@docker compose -p $(COMPOSE_PROJECT_NAME) -f $(COMPOSE_FILE) restart

logs: ## Follow logs from running platform services (usage: make logs SERVICE=traefik)
	@if [ -z "$(SERVICE)" ]; then \
		docker compose -p $(COMPOSE_PROJECT_NAME) -f $(COMPOSE_FILE) logs -f; \
	else \
		docker compose -p $(COMPOSE_PROJECT_NAME) -f $(COMPOSE_FILE) logs -f $(SERVICE); \
	fi

ps: ## List all platform containers with status
	@docker compose -p $(COMPOSE_PROJECT_NAME) -f $(COMPOSE_FILE) ps

doctor: ## Run comprehensive health checks (Phase 10)
	@bash scripts/doctor.sh

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

upgrade: ## Upgrade platform (backup, pull images, recreate, doctor)
	@echo "==> Step 1/4: Creating pre-upgrade backup..."
	@$(MAKE) backup || (echo "Backup failed - aborting upgrade" && exit 1)
	@echo "==> Step 2/4: Pulling latest images..."
	@docker compose -p $(COMPOSE_PROJECT_NAME) -f $(COMPOSE_FILE) pull
	@echo "==> Step 3/4: Recreating services..."
	@docker compose -p $(COMPOSE_PROJECT_NAME) -f $(COMPOSE_FILE) up -d --force-recreate
	@echo "==> Step 4/4: Running health checks..."
	@$(MAKE) doctor
	@echo "Upgrade complete!"

rollback: ## Rollback hint (manual: restore from latest backup)
	@echo "To rollback:"
	@echo "  1. Stop stack: make down"
	@echo "  2. List backups: make backup-list"
	@echo "  3. Restore: make restore SNAPSHOT=nexusops-..."
	@echo "  4. Start stack: make up"

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

env-check: ## Validate .env file has all required variables
	@bash scripts/env-check.sh

test: ## Run full test suite (smoke + integration + sql + restore)
	@echo "==> Running smoke tests..."
	@bash tests/smoke/smoke.sh
	@echo "==> Running SQL tests..."
	@docker exec -i nexusops_postgres psql -U nexusops -d nexusops -f tests/sql/test_llm_cost.sql
	@echo "==> Running integration tests..."
	@if command -v pytest >/dev/null 2>&1; then \
		pytest tests/integration -v --tb=short; \
	else \
		echo "pytest not installed. Run: pip install pytest pytest-asyncio httpx docker asyncpg"; \
	fi
	@echo "==> Running restore tests..."
	@bash tests/restore/restore_test.sh
	@echo "All tests passed!"

test-fast: ## Run only smoke tests (fastest)
	@bash tests/smoke/smoke.sh

test-smoke: ## Run smoke tests only
	@bash tests/smoke/smoke.sh

test-integration: ## Run integration tests only (requires pytest)
	@if command -v pytest >/dev/null 2>&1; then \
		pytest tests/integration -v --tb=short; \
	else \
		echo "pytest not installed. Run: pip install pytest pytest-asyncio httpx docker asyncpg"; \
	fi

test-sql: ## Run SQL tests only
	@docker exec -i nexusops_postgres psql -U nexusops -d nexusops -f tests/sql/test_llm_cost.sql

test-restore: ## Run restore test only
	@bash tests/restore/restore_test.sh

clean: ## Remove all containers, volumes, and networks (with confirmation)
	@echo "⚠️  This will DELETE all data including volumes!"
	@read -p "Type 'yes' to confirm: " confirm; \
	if [ "$$confirm" = "yes" ]; then \
		docker compose -p $(COMPOSE_PROJECT_NAME) -f $(COMPOSE_FILE) down -v --remove-orphans; \
		docker volume prune -f; \
		echo "Cleanup complete."; \
	else \
		echo "Cancelled."; \
	fi