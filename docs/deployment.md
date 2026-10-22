# NexusOps Deployment Guide

## Server Sizing

| Component | Min CPU | Min RAM | Recommended CPU | Recommended RAM | Disk |
|-----------|---------|---------|-----------------|-----------------|------|
| **Traefik** | 0.1 | 64 MB | 0.25 | 128 MB | 1 GB |
| **n8n Main** | 0.5 | 512 MB | 1 | 1 GB | 2 GB |
| **n8n Webhook** | 0.25 | 256 MB | 0.5 | 512 MB | 1 GB |
| **n8n Worker (×2)** | 0.25 | 256 MB | 0.5 | 512 MB | 1 GB each |
| **PostgreSQL 16** | 0.5 | 512 MB | 1 | 1 GB | 10 GB+ |
| **Redis 7** | 0.1 | 128 MB | 0.25 | 256 MB | 2 GB |
| **Qdrant** | 0.5 | 512 MB | 1 | 1 GB | 5 GB+ |
| **Backup Service** | 0.1 | 64 MB | 0.25 | 128 MB | Backup volume |
| **Socket Proxy** | 0.05 | 32 MB | 0.1 | 64 MB | — |
| **Total (base)** | **2.5 vCPU** | **2.5 GB** | **5 vCPU** | **5 GB** | **25 GB+** |

**Production tip:** Run on 2× the recommended for headroom. Use separate disks for Postgres data and backups.

## DNS Configuration

### Local Development (`.localhost`)
No DNS needed. Add to `/etc/hosts`:
```bash
127.0.0.1 n8n.localhost traefik.localhost qdrant.localhost
```
`*.localhost` resolves to `127.0.0.1` by RFC 6761.

### Production Domain
Create A records:
```
n8n.yourdomain.com     A  <server-ip>
traefik.yourdomain.com A  <server-ip>
qdrant.yourdomain.com  A  <server-ip>   # optional, opt-in
```
Set in `.env`:
```bash
DOMAIN=yourdomain.com
LE_EMAIL=admin@yourdomain.com
N8N_HOST=n8n.yourdomain.com
N8N_PROTOCOL=https
WEBHOOK_URL=https://n8n.yourdomain.com/
```

## Firewall (UFW Example)

```bash
# Allow SSH (adjust port if changed)
ufw allow 22/tcp

# HTTP/HTTPS for Traefik
ufw allow 80/tcp
ufw allow 443/tcp

# Optional: Traefik dashboard (restrict to your IP)
ufw allow from <YOUR_IP> to any port 8080

# Deny all other incoming
ufw default deny incoming
ufw default allow outgoing
ufw enable
```

**Note:** Docker bypasses UFW for published ports. The above works because only Traefik publishes 80/443. Internal services (Postgres, Redis, Qdrant, n8n) are on `internal: true` networks and not published.

## First Deploy

### 1. Prerequisites
- Docker Engine 24+ with Compose v2
- Git
- (Optional) `age`, `htpasswd`, `openssl` for secret generation

### 2. Clone & Configure
```bash
git clone https://github.com/nexusops/nexusops.git
cd nexusops
cp .env.example .env
```

### 3. Generate Secrets
```bash
# Make executable and run
chmod +x scripts/generate-secrets.sh
./scripts/generate-secrets.sh
```
This fills `.env` with secure random values for all required secrets. **Back up `N8N_ENCRYPTION_KEY` and Age private key offline!**

### 4. Manual `.env` Edits (Required)
```bash
# Edit .env and set these:
LE_EMAIL=your-email@domain.com
DOMAIN=yourdomain.com          # or localhost for local
N8N_HOST=n8n.yourdomain.com
N8N_PROTOCOL=https
WEBHOOK_URL=https://n8n.yourdomain.com/
BACKUP_AGE_RECIPIENT=age1...   # from age-keygen (public key only!)
# Optional:
ALERT_TELEGRAM_BOT_TOKEN=...
ALERT_TELEGRAM_CHAT_ID=...
DEFAULT_APPROVER_PRIMARY=123456789
DEFAULT_APPROVER_SECONDARY=987654321
```

### 5. Deploy
```bash
# Base mode (HTTP, localhost)
make up

# Production mode (HTTPS, Let's Encrypt)
COMPOSE_FILE=compose.yaml:compose.prod.yaml make up
```

### 6. Verify
```bash
make doctor
# All checks should PASS
```

### 7. Access n8n
- Base: `http://n8n.localhost` (add to `/etc/hosts`)
- Prod: `https://n8n.yourdomain.com`
- First visit: n8n setup screen → create owner account

### 8. Run Bootstrap (Import Workflows)
```bash
# The n8n-bootstrap one-shot service runs automatically after n8n is healthy
# Check logs:
make logs SERVICE=n8n-bootstrap
# Should show: "Bootstrap completed successfully"
```

### 9. Optional: Enable Monitoring
```bash
COMPOSE_FILE=compose.yaml:compose.monitoring.yaml make up
# Uptime Kuma: http://localhost:3001
# Grafana: http://localhost:3000 (admin/admin from .env)
# Prometheus: http://localhost:9090
```

## Post-Deploy Configuration

### n8n Settings
1. Log into n8n UI
2. Settings → General → Set **Webhook URL** to match `WEBHOOK_URL`
3. Settings → Execution → Enable **Queue Mode** (already set via env)

### Telegram Alerts
1. Create bot via @BotFather → get token
2. Get chat ID: message bot, then `curl "https://api.telegram.org/bot<TOKEN>/getUpdates"`
3. Add to `.env`: `ALERT_TELEGRAM_BOT_TOKEN`, `ALERT_TELEGRAM_CHAT_ID`
4. Restart: `make restart`

### S3 Offsite Backup
```bash
BACKUP_S3_ENABLED=true
BACKUP_S3_ENDPOINT=https://s3.amazonaws.com  # or MinIO endpoint
BACKUP_S3_BUCKET=your-bucket
BACKUP_S3_PREFIX=nexusops
BACKUP_S3_ACCESS_KEY=...
BACKUP_S3_SECRET_KEY=...
BACKUP_S3_REGION=us-east-1
make restart
```

## Upgrade Procedure

```bash
# Automated (backup → pull → recreate → doctor)
make upgrade

# Or manual:
make backup
docker compose -p nexusops -f compose.yaml pull
docker compose -p nexusops -f compose.yaml up -d --force-recreate
make doctor
```

### Rollback
```bash
make down
make backup-list
make restore SNAPSHOT=nexusops-20261022T030000Z
make up
```

## Backup Key Handling

### Age Key Pair (Generate Offline)
```bash
# On secure offline machine
age-keygen -o age-key.txt
# age-key.txt contains:
# AGE-SECRET-KEY-... (PRIVATE — NEVER ON SERVER)
# age1... (PUBLIC — put in BACKUP_AGE_RECIPIENT)
```

### Key Storage
| Key | Location | Access |
|-----|----------|--------|
| Age private key | Offline (password manager, hardware token, printed QR) | Human only |
| Age public key | `.env` as `BACKUP_AGE_RECIPIENT` | Backup service (read-only) |
| n8n encryption key | `.env` + n8n data volume | n8n services + backup |
| Postgres/Redis passwords | `.env` + Docker secrets | Respective services |

### Key Rotation
```bash
# Age: generate new pair, update BACKUP_AGE_RECIPIENT, keep old private key for old backups
# n8n encryption key: see docs/operations.md (requires re-entering all credentials)
# DB/Redis passwords: see docs/operations.md (restart affected services)
```

## Common Deployment Problems

| Problem | Cause | Fix |
|---------|-------|-----|
| `make doctor` shows Traefik unhealthy | Port 80/443 in use | Stop conflicting service (Apache, Nginx) or change Traefik ports |
| n8n setup screen doesn't load | n8n not healthy yet | Wait for `make doctor` PASS, check `make logs SERVICE=n8n-main` |
| Webhooks return 502 | Traefik can't reach n8n-webhook | Check `make doctor`, verify n8n-webhook healthy |
| `make backup` fails | `BACKUP_AGE_RECIPIENT` not set | Run `./scripts/generate-secrets.sh` or add Age public key to `.env` |
| Qdrant healthcheck fails | API key mismatch | Verify `QDRANT_API_KEY` in `.env` matches Qdrant env |
| Telegram alerts not sent | Bot token/chat ID wrong | Verify `ALERT_TELEGRAM_BOT_TOKEN`, `ALERT_TELEGRAM_CHAT_ID` |
| `make upgrade` aborts | Backup step failed | Fix backup first (`make backup`), then retry |
| Out of disk space | `make doctor` shows disk FAIL | `docker system prune -f`, clean old backups, scale down logs |

## Next Steps
- [Operations Guide](operations.md) — Day-2 operations
- [Architecture](architecture.md) — System design
- [Backup & Restore](backup-restore.md) — RPO/RTO, disaster recovery