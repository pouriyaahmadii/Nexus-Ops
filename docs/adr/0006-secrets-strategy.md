# ADR 0006: Secrets Strategy — No Secrets in Repo, Age + .env

## Status
Accepted

## Date
2026-10-22

## Context
The platform requires numerous secrets: database passwords, Redis password, Qdrant API key, n8n encryption key, backup encryption key, Telegram tokens, S3 credentials, etc. These must never be committed to the repository.

## Decision
Use a layered secrets strategy:

1. **`.env.example`** — Template with all variable names, descriptions, and safe placeholders. Committed.
2. **`.env`** — Actual secrets, generated locally via `scripts/generate-secrets.sh`. Gitignored.
3. **Age encryption** — Backup artifacts encrypted with `age` using a public key (`BACKUP_AGE_RECIPIENT`). Private key **never on server**.
4. **Docker secrets** — For runtime secrets that support it (PostgreSQL, Redis via `_FILE` vars).
4. **n8n credentials** — Stored in n8n's encrypted database (encrypted by `N8N_ENCRYPTION_KEY`), created via bootstrap from `.env`.

## Consequences

### Positive
- **Zero secrets in git**: `.env` in `.gitignore`, `gitleaks` scans history in CI
- **Operator-friendly**: Single `.env` file to manage, `generate-secrets.sh` fills it
- **Backup security**: Age public-key encryption means server compromise ≠ backup decryption
- **Rotation support**: `generate-secrets.sh` is idempotent (only fills empty values)
- **n8n integration**: Credentials managed in n8n UI, encrypted at rest

### Negative / Trade-offs
- **Manual step**: Operator must run `cp .env.example .env` and fill/generate secrets
- **Private key management**: Age private key must be stored offline (password manager, hardware token)
- **Bootstrap dependency**: n8n credentials created at startup from `.env`; if `.env` changes, credentials must be re-synced

### Neutral
- Docker secrets used for Postgres/Redis passwords (files in `/run/secrets/`)
- S3 credentials only needed if `BACKUP_S3_ENABLED=true`

## Implementation
- `scripts/generate-secrets.sh`: Idempotent, uses `openssl`/`htpasswd`, sets `.env` to 600
- `.env.example`: Every variable documented with purpose, format, example
- `BACKUP_AGE_RECIPIENT`: Age public key (format `age1...`) in `.env`
- Age private key: **Never on server**, stored offline

## Key Generation Commands
```bash
# Age key pair (offline)
age-keygen -o age-key.txt
# Output: public key (age1...) + private key (AGE-SECRET-KEY-...)

# PostgreSQL/Redis passwords
openssl rand -base64 32

# n8n encryption key (32 bytes base64)
openssl rand -base64 32

# Traefik dashboard bcrypt (for TRAEFIK_DASHBOARD_PASSWORD)
htpasswd -nbB admin <password>  # Escape $ as $$ for Compose

# Telegram bot token: from @BotFather
# DLQ replay token: openssl rand -base64 32
```