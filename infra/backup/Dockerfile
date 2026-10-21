# AutoForge / NexusOps - Backup service image
# Based on Alpine Linux with minimal required tools for encrypted backups.
# Runs as non-root user (UID 1000) where possible.

FROM alpine:3.21

# Install required packages
# postgresql-client: pg_dump, pg_restore
# restic: backup repository management, encryption, retention
# age: file encryption (alternative to restic's built-in, for manifest)
# curl: healthchecks, Qdrant API
# jq: JSON parsing for manifests and API responses
# tzdata: timezone support for cron
# supercronic: lightweight cron daemon
# bash: script execution
# coreutils: standard utilities
RUN apk add --no-cache \
    postgresql-client=17.5-r0 \
    restic=0.18.0-r0 \
    age=1.2.1-r0 \
    curl=8.10.1-r0 \
    jq=1.7.1-r2 \
    tzdata=2025b-r0 \
    supercronic=0.2.3-r0 \
    bash=5.2.37-r0 \
    coreutils=9.5-r1 \
    openssl=3.3.2-r3 \
    findutils=4.10.0-r0

# Create non-root user and directories
RUN adduser -D -u 1000 -g "backup user" backup && \
    mkdir -p /backup/data /backup/tmp /scripts && \
    chown -R backup:backup /backup /scripts

# Copy backup scripts
COPY scripts/ /scripts/
RUN chmod +x /scripts/*.sh && \
    chown -R backup:backup /scripts

# Healthcheck endpoint
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD /scripts/healthcheck.sh || exit 1

# Switch to non-root user
USER backup

# Default entrypoint runs supercronic with crontab
ENTRYPOINT ["supercronic"]
CMD ["/scripts/crontab"]