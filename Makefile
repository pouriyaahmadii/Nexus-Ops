# ==============================================================================
# NexusOps - Production Automation Platform Makefile
# ==============================================================================
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

COMPOSE_PROJECT_NAME ?= nexusops

.PHONY: help up down logs ps doctor config backup restore-test demo lint

help: ## Print this formatted list of targets with descriptions
	@echo "NexusOps Management CLI"
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

up: ## Start the platform services in background
	@echo "==> Starting NexusOps services under namespace $(COMPOSE_PROJECT_NAME)..."
	docker compose -p $(COMPOSE_PROJECT_NAME) up -d

down: ## Stop and remove all platform containers
	@echo "==> Stopping NexusOps services..."
	docker compose -p $(COMPOSE_PROJECT_NAME) down --remove-orphans

logs: ## Follow logs from running platform services
	docker compose -p $(COMPOSE_PROJECT_NAME) logs -f

ps: ## List running platform services and health status
	docker compose -p $(COMPOSE_PROJECT_NAME) ps

doctor: ## Run diagnostic checks on system requirements and ports
	@./scripts/doctor.sh

config: ## Validate docker compose specification
	docker compose -p $(COMPOSE_PROJECT_NAME) config -q

backup: ## Trigger encrypted database and config backup (Phase 5)
	@echo "[backup] Placeholder: Backup automation will be introduced in Phase 5."

restore-test: ## Run backup restore drill in an isolated environment (Phase 5)
	@echo "[restore-test] Placeholder: Backup drill test will be introduced in Phase 5."

demo: ## Run end-to-end showcase workflow (Phase 9)
	@echo "[demo] Placeholder: Showcase workflow trigger will be introduced in Phase 9."

lint: ## Run syntax and lint checks across repository files
	@echo "==> Running syntax and hygiene checks..."
	@if command -v pre-commit >/dev/null 2>&1; then \
		pre-commit run --all-files; \
	else \
		echo "pre-commit is not installed locally. Run: pip install pre-commit"; \
	fi
