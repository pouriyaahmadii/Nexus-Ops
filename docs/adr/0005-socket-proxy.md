# ADR 0005: Docker Socket Proxy for Traefik

## Status
Accepted

## Date
2026-10-22

## Context
Traefik's Docker provider requires access to the Docker socket (`/var/run/docker.sock`) to discover services and read labels. Mounting the socket directly gives Traefik root-equivalent access to the host Docker daemon, which is a significant security risk if Traefik is compromised.

## Decision
Deploy **tecnativa/docker-socket-proxy** (or equivalent) as a read-only proxy in front of the Docker socket, granting Traefik only the API endpoints it needs.

## Consequences

### Positive
- **Least privilege**: Traefik only accesses `/containers/json`, `/images/json`, `/events`, `/version` — no container exec, build, or daemon control
- **Network isolation**: Proxy runs in `app` network, Traefik talks to proxy, not host socket
- **Audit trail**: Proxy logs all API calls
- **Standard practice**: Recommended by Traefik and Docker security guides

### Negative / Trade-offs
- **Additional container**: One more component to maintain and monitor
- **Latency**: Negligible (<1ms) for label discovery
- **Configuration complexity**: Must configure proxy permissions correctly

### Neutral
- The proxy image (`tecnativa/docker-socket-proxy:latest`) is small (~10MB) and well-maintained

## Implementation
```yaml
# In compose.yaml
services:
  docker-socket-proxy:
    image: tecnativa/docker-socket-proxy:latest
    container_name: nexusops_docker_socket_proxy
    environment:
      CONTAINERS: 1      # List containers
      IMAGES: 1          # List images
      EVENTS: 1          # Stream events for real-time updates
      VERSION: 1         # Docker version
      # Explicitly deny: BUILD, COMMIT, CREATE, EXEC, NETWORKS, NODES, PLUGINS, SECRETS, SERVICES, SYSTEM
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock:ro
    networks: [app]
    restart: unless-stopped

  traefik:
    # ...
    environment:
      - DOCKER_HOST=tcp://docker-socket-proxy:2375
    depends_on:
      - docker-socket-proxy
    # Remove: - /var/run/docker.sock:/var/run/docker.sock:ro
```

## Security Note
The proxy runs as non-root (UID 1000) with `no-new-privileges` and read-only root filesystem where possible.