# AGENTS.md - NexusOps Workspace Rules & Global Governance

## 1. Project Identity & Scope
- Project Name: NexusOps (Production-Grade Self-Hosted Automation Platform, formerly AutoForge).
- Compose Namespace: strictly `COMPOSE_PROJECT_NAME=nexusops`.
- Workspace Root: Strictly execute inside `./`. Never inspect or modify parent `../` paths.
- Tech Stack: Traefik v3, n8n (Queue Mode), PostgreSQL 16, Redis 7, Qdrant, Docker Compose v2.

## 2. Port & Resource Isolation
- Traefik Entrypoints: Bind Web to `80` (or `8080` for unprivileged mode) and Websecure to `443` (or `8443`).
- PostgreSQL: Network internal only (`internal: true`). If published locally on host, strictly use `5433` (never `5432`). Container prefix: `nexusops_postgres`.
- Redis: Network internal only (`internal: true`). If published locally on host, strictly use `6380` (never `6379`). Container prefix: `nexusops_redis`.
- Qdrant: Host port `6333`. Container prefix: `nexusops_qdrant`.
- n8n (Main, Webhook, Workers): No direct host ports; access exclusively via Traefik routing (`*.localhost`).
- Forbidden Ports: Never bind or kill processes on ports `3000`, `8000`, `5432`, `6379`, or `5678` (reserved for host and external workspaces).

## 3. Principles
- Secure by default, reproducible, idempotent, documented, tested.
- Prefer boring, well-known solutions over clever ones. Explain trade-offs in ADRs.
- Never hardcode secrets. Never commit real credentials. Use `.env.example` with clear placeholders.
- Pin all image versions to explicit tags (never `:latest`) and add comments explaining how to bump them.
- Every service must have a healthcheck, restart policy, resource limits, and run as a non-root user with a read-only root filesystem wherever possible.
- Networks must be strictly segmented:
  - `edge`: External reverse-proxy ingress network.
  - `app`: Internal application bridge connecting Traefik and n8n instances.
  - `data`: Isolated data tier (`internal: true`) for PostgreSQL, Redis, and Qdrant.
- Shell scripts must start with `set -euo pipefail`, be shellcheck-clean, and idempotent.
- Compose files follow Docker Compose v2 specification (`compose.yaml`). Do not use top-level `version:` key.
- Human entrypoints are Makefile targets; each target must include a `##` help comment.

## 4. Shell & Execution Safety
- Never run `docker system prune` or global process termination commands.
- Always run Docker Compose commands with the project flag: `docker compose -p nexusops <command>`.
- Shell scripts must use `set -euo pipefail` and validate project names before executing teardowns or modifications.

## 5. Quality Bar & Standards
- Use Conventional Commits for all commit messages (`feat(...)`, `fix(...)`, `docs(...)`, etc.).
- Update documentation in the same change as the code it describes.
- Keep files small, modular, and focused. No dead code or orphaned TODOs without an issue reference.
- Prefer configuration through environment variables documented in `.env.example`.

## 6. Honesty Rules
- Never claim something was tested or verified unless actually executed.
- If a command cannot be executed (e.g. Docker daemon is unreachable), state so explicitly and provide the exact command for manual verification.
- Do not fabricate benchmark numbers, version numbers, or unsupported features.

## 7. Definition of Done (DoD) for Every Task
1. All acceptance criteria in the task are met.
2. `docker compose -p nexusops config -q` passes without warnings or errors.
3. Linters pass (shellcheck, yamllint, syntax validation) where applicable.
4. Documentation is updated.
5. Final message contains: what changed, how it was verified, known limitations, and a suggested commit message.
