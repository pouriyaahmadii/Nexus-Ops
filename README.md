# NexusOps

[![CI](https://github.com/nexusops/nexusops/workflows/CI/badge.svg)](https://github.com/nexusops/nexusops/actions/workflows/ci.yml)
[![Security](https://github.com/nexusops/nexusops/workflows/Security/badge.svg)](https://github.com/nexusops/nexusops/actions/workflows/security.yml)
[![Release](https://github.com/nexusops/nexusops/workflows/Release/badge.svg)](https://github.com/nexusops/nexusops/actions/workflows/release.yml)

Production-grade self-hosted automation platform built on **n8n**, **Traefik**, **PostgreSQL**, **Redis**, and **Qdrant**.

> **Status:** Work in progress — see [CHANGELOG](CHANGELOG.md) for current version.

## Features

- **Queue Mode n8n**: Separate main, webhook processor, and scalable workers
- **Automatic HTTPS**: Traefik with Let's Encrypt and HTTP→HTTPS redirect
- **Encrypted Backups**: Age-encrypted, restic-managed, with automated restore drills
- **Error Handling**: Global error handler, retry with backoff, dead-letter queue
- **LLM Cost Tracking**: Usage ledger, pricing, budget guard with auto-enforcement
- **Human-in-the-Loop**: Approval flows with Telegram, escalation, audit trail
- **Observability**: `make doctor`, optional Uptime Kuma + Prometheus + Grafana
- **CI/CD**: Lint, security scans, smoke tests, restore drills, automated releases

## Quick Start

```bash
# 1. Clone and configure
git clone https://github.com/nexusops/nexusops.git
cd nexusops
cp .env.example .env
# Edit .env with your secrets (see docs/operations.md)

# 2. Start platform
make up

# 3. Verify
make doctor
# All checks should PASS

# 4. Access n8n
# http://n8n.localhost (add to /etc/hosts: 127.0.0.1 n8n.localhost traefik.localhost qdrant.localhost)
```

## Documentation

| Topic | File |
|-------|------|
| Architecture | [docs/architecture.md](docs/architecture.md) |
| Error Handling | [docs/error-handling.md](docs/error-handling.md) |
| LLM Cost Tracking | [docs/llm-cost-tracking.md](docs/llm-cost-tracking.md) |
| Human-in-the-Loop | [docs/human-in-the-loop.md](docs/human-in-the-loop.md) |
| Backup & Restore | [docs/backup-restore.md](docs/backup-restore.md) |
| Operations Guide | [docs/operations.md](docs/operations.md) |
| Demo Showcase | [docs/demo.md](docs/demo.md) |
| CI/CD Guide | [docs/contributing-ci.md](docs/contributing-ci.md) |

## Commands

```bash
make help          # List all commands
make up            # Start platform
make down          # Stop platform
make logs          # Follow logs (SERVICE=name for specific)
make ps            # Container status
make doctor        # Full health check
make scale WORKERS=4  # Scale n8n workers
make backup        # Trigger encrypted backup
make restore-test  # Run restore drill
make demo          # Run end-to-end demo (mock mode)
make upgrade       # Backup → pull → recreate → doctor
make lint          # Run all linters
make clean         # Remove everything (with confirmation)
```

## CI/CD

- **Lint**: yamllint, shellcheck, hadolint, actionlint, JSON validation
- **Security**: Gitleaks (secrets), Trivy (FS, config, image), Dependency Review
- **Tests**: Smoke test (full stack), SQL unit tests, restore drill (weekly)
- **Release**: Conventional Commits → release-please → multi-arch image → GHCR

## License

MIT License — see [LICENSE](LICENSE)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/contributing-ci.md](docs/contributing-ci.md)