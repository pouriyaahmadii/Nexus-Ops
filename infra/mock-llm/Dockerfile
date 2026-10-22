# AutoForge / NexusOps - Mock LLM Service for Demo Mode
# Returns deterministic classifications, token counts, and occasional injected failures.

FROM python:3.12-alpine

WORKDIR /app

# Install only required packages
RUN apk add --no-cache curl

COPY mock_llm.py /app/
RUN chmod +x /app/mock_llm.py

EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
    CMD curl -fsS http://localhost:8080/health || exit 1

CMD ["python3", "/app/mock_llm.py"]