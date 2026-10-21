# n8n queue mode benchmarks

This document describes how to compare n8n execution throughput with
different worker counts using `workflows/demo/benchmark.json`.

## Prerequisites

1. Start the stack in queue mode:

   ```bash
   cp .env.example .env   # fill secrets (Phase 3 generator)
   make up                # base mode, plain HTTP on *.localhost
   ```

2. Import `workflows/demo/benchmark.json` into n8n (UI → Workflows → Import)
   and activate it. The webhook is available at:

   ```
   http://n8n.localhost/webhook/bench
   ```

## Baseline (1 worker)

```bash
make scale WORKERS=1
# run N concurrent POSTs to http://n8n.localhost/webhook/bench
# record: average response time, executions/min, errors
```

## Scaled (4 workers)

```bash
make scale WORKERS=4
# repeat the same load
```

`make scale WORKERS=N` uses `docker compose up -d --scale n8n-worker=N --no-recreate`,
so the UI (n8n-main) keeps running while workers are added/removed.

## Results table

| Workers | Concurrent requests | Avg response time | Executions / min | Errors | Notes |
|---------|--------------------:|------------------:|-----------------:|--------|-------|
| 1       |                     |                   |                  |        |       |
| 2       |                     |                   |                  |        | default |
| 4       |                     |                   |                  |        |       |

Fill the cells after running the drill. Do not invent numbers.

## What to watch

- `make workers` shows worker container status.
- `docker compose -p nexusops logs n8n-worker` shows which worker picked up each execution.
- Webhooks should keep answering while `n8n-main` restarts (webhook processor is separate).
- Execution distribution: each execution should be handled by a different worker over repeated runs.
