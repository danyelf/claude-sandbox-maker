# Multi-Agent Docker Container
# Runs Claude Code agents with beads coordination

FROM ubuntu:24.04

# Prevent interactive prompts during package installation
ENV DEBIAN_FRONTEND=noninteractive

# Install system dependencies
RUN apt-get update && apt-get install -y \
    git \
    curl \
    jq \
    ca-certificates \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# Install Node.js 20 LTS
RUN curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y nodejs \
    && rm -rf /var/lib/apt/lists/*

# Install Claude Code globally
RUN npm install -g @anthropic-ai/claude-code

# Install beads CLI from GitHub releases
ARG BEADS_VERSION=0.47.0
ARG TARGETARCH
RUN curl -fsSL "https://github.com/steveyegge/beads/releases/download/v${BEADS_VERSION}/beads_${BEADS_VERSION}_linux_${TARGETARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin bd \
    && chmod +x /usr/local/bin/bd

# Create non-root user with fixed UID (Claude Code refuses to run as root)
# Use UID 1001 to avoid conflict with default ubuntu user
RUN useradd -m -s /bin/bash -u 1001 agent \
    && mkdir -p /workspace \
    && chown -R agent:agent /workspace

# Configure git for agent user
USER agent
RUN git config --global init.defaultBranch main \
    && git config --global credential.helper store \
    && git config --global safe.directory /workspace/main \
    && git config --global safe.directory /workspace/agent1 \
    && git config --global safe.directory /workspace/agent2 \
    && git config --global safe.directory /workspace/agent3 \
    && git config --global safe.directory /workspace/agent4

# Create workspace directory
WORKDIR /workspace/main

# Copy entrypoint script (as root, then switch back)
USER root
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Run as non-root agent user
USER agent

ENTRYPOINT ["/entrypoint.sh"]
