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

# Install Claude Code and beads CLI globally
RUN npm install -g @anthropic-ai/claude-code beads-cli

# Configure git (agents will use GITHUB_TOKEN for auth)
RUN git config --global init.defaultBranch main \
    && git config --global credential.helper store

# Create workspace directory
WORKDIR /workspace/main

# Copy entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Container runs as root within Docker isolation
# The workspace volume is the only accessible filesystem

ENTRYPOINT ["/entrypoint.sh"]
