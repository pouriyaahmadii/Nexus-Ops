# ADR 0004: Traefik over Nginx as Reverse Proxy

## Status
Accepted

## Date
2026-10-22

## Context
The platform needs a production-grade reverse proxy with automatic HTTPS, Let's Encrypt integration, Docker provider discovery, and middleware support for security headers, rate limiting, and authentication.

Options evaluated:
1. **Traefik v3** — Native Docker provider, automatic HTTPS via ACME, dynamic configuration, middleware pipeline, metrics endpoint
2. **Nginx** — Mature, widely used, but requires external tools (certbot, nginx-proxy) for auto-HTTPS and service discovery
3. **Caddy** — Automatic HTTPS, simple config, but less flexible middleware and no native Docker provider in v2

## Decision
Use **Traefik v3** as the edge reverse proxy.

## Consequences

### Positive
- **Native Docker provider**: Discovers services via labels automatically (`exposedByDefault=false`)
- **Let's Encrypt built-in**: HTTP challenge on port 80, stores certs in volume, zero-config renewal
- **Dynamic configuration**: File provider watches `infra/traefik/dynamic/` for middleware/routers
- **Middleware pipeline**: Security headers, rate limiting, basic auth, redirect, TLS config as reusable components
- **Metrics & dashboard**: Prometheus metrics, web UI for debugging routes
- **v3 improvements**: Better performance, improved middleware, Kubernetes CRD support if needed later

### Negative / Trade-offs
- **Learning curve**: Different from Nginx config syntax
- **Single point of failure**: Mitigated by running multiple replicas in production (future)
- **Dashboard exposure**: Must be secured (basic auth + TLS, not published in base mode)

### Neutral
- Migration from Nginx would require rewriting all routing rules as labels
- Traefik's YAML/TOML config is version-controlled alongside compose files

## Implementation Notes
- Static config: `infra/traefik/traefik.yml` (entrypoints, providers, ACME)
- Dynamic config: `infra/traefik/dynamic/middlewares.yml` (security headers, rate limit, auth)
- Base mode: HTTP only on port 80, `api.insecure=true` (dashboard on :8080 not published)
- Prod mode: HTTPS on 443, ACME HTTP challenge, `api.insecure=false`, dashboard behind basic auth on `traefik.${DOMAIN}`