# ADR 0003: Choose restic for encrypted backup storage and retention

## Status
Accepted

## Date
2026-10-22

## Context
The backup system (Phase 5) needs to store encrypted artifacts with configurable retention policies (daily 7, weekly 4, monthly 6) and optional offsite sync to S3-compatible storage. Two main approaches were evaluated:

1. **restic** - Backup program with built-in encryption, deduplication, retention policies, and S3 support
2. **rclone + age** - Sync tool with external encryption (age) and manual retention logic

## Decision
Use **restic** as the primary backup repository manager for both local and S3 storage.

## Consequences

### Positive
- **Built-in encryption**: AES-256 with repository password, no separate encryption step needed for repository contents
- **Deduplication**: Content-addressable storage reduces space for repeated backups
- **Native retention**: `restic forget --keep-daily/weekly/monthly --prune` implements policy declaratively
- **S3 native**: Direct support for S3-compatible endpoints (MinIO, AWS S3, Wasabi, etc.)
- **Repository integrity**: `restic check` verifies repository consistency
- **Single tool**: Simplifies operational knowledge and scripting

### Negative / Trade-offs
- **Learning curve**: Restic repository model differs from simple file copy
- **Private key management**: Restic uses a repository password; age public-key encryption is kept for the manifest/artifacts layer to allow offline decryption without restic
- **Mount requirement**: Restoring individual files requires `restic mount` (FUSE) or full repository restore

### Neutral
- Local backups still written as encrypted files (age) for portability; restic used for retention/S3 sync layer
- The `BACKUP_AGE_RECIPIENT` public key encrypts individual artifacts; restic repository password is separate (`RESTIC_PASSWORD` derived from same env for simplicity)

## Alternatives Considered
- **rclone + age + manual retention**: More transparent file layout but requires custom retention script; rclone doesn't do deduplication
- **borgbackup**: Similar to restic but less common in containerized environments; Python-based (larger image)

## Implementation Notes
- Backup service image includes restic 0.18.0
- Local retention falls back to simple directory aging (simplified); production should use restic local repo
- S3 sync uses `restic backup` to push local encrypted artifacts to restic repository on S3
- Age encryption kept for artifact portability (can decrypt with private key without restic)