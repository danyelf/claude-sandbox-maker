#!/bin/bash
# shellcheck shell=bash
set -eux -o pipefail

# Install base system packages for Claude Sandbox

echo "CSB_PROGRESS:Updating package lists"
apt-get update

echo "CSB_PROGRESS:Installing base packages (git, tmux, python3, nodejs)"
apt-get install -y --no-install-recommends \
  tmux \
  git \
  curl \
  wget \
  ca-certificates \
  build-essential \
  python3 \
  python3-pip \
  python3-venv \
  nodejs \
  npm \
  jq \
  iptables \
  dnsutils \
  dnsmasq

# Clean up apt cache
apt-get clean
rm -rf /var/lib/apt/lists/*
