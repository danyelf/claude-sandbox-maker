# Minimal stub for testing docker-compose orchestration
# TODO: Replace with full agent container (csb-hai)
FROM ubuntu:24.04

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /workspace/main

# Stub entrypoint - just verify environment and workspace
CMD ["sh", "-c", "echo \"Agent $AGENT_ID started\"; echo \"Workspace contents:\"; ls -la /workspace/main 2>/dev/null || echo 'Workspace empty'; echo \"Waiting...\"; sleep infinity"]
