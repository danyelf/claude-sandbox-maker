#!/bin/bash
# shellcheck disable=SC2016  # We intentionally use single quotes to defer variable expansion
# 02-user-setup.sh - User-mode provisioning for Claude Sandbox
# Installs Claude Code CLI, beads CLI, and configures plugin installation
#
# This script runs as the regular user (not root) during Lima provisioning.

set -eux -o pipefail

# Configure npm to use user-writable directory for global packages
mkdir -p ~/.npm-global
npm config set prefix ~/.npm-global
export PATH="$HOME/.npm-global/bin:$PATH"
# Add to both .bashrc (interactive) and .profile (login shells)
echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> ~/.bashrc
echo 'export PATH="$HOME/.npm-global/bin:$PATH"' >> ~/.profile

echo "CSB_PROGRESS:Installing Claude Code CLI"
npm install -g @anthropic-ai/claude-code

echo "CSB_PROGRESS:Installing beads CLI"
# Timeout after 60s - postinstall downloads binaries and can hang on slow networks
START_TIME=$(date +%s)
NPM_OUTPUT=$(timeout 60 npm install -g @beads/bd 2>&1) && NPM_OK=true || NPM_OK=false
END_TIME=$(date +%s)
if [ "$NPM_OK" = "false" ]; then
  # Run diagnostics only on failure to help debug network issues
  DIAG_LOG="/tmp/beads-install-diag.log"
  {
    echo "=== Beads Install Diagnostics $(date) ==="
    echo "--- Install failed after $((END_TIME - START_TIME))s ---"
    echo "--- NPM Output ---"
    echo "$NPM_OUTPUT"
    echo "--- DNS Resolution ---"
    dig +short github.com 2>&1 || true
    dig +short registry.npmjs.org 2>&1 || true
    echo "--- GitHub Connectivity ---"
    curl -sI --connect-timeout 5 https://github.com 2>&1 | head -5 || true
    echo "--- NPM Registry ---"
    curl -sI --connect-timeout 5 https://registry.npmjs.org/@beads/bd 2>&1 | head -5 || true
  } > "$DIAG_LOG" 2>&1
  NPM_ERROR=$(echo "$NPM_OUTPUT" | grep -i "error\|ERR!" | tail -1 | cut -c1-80)
  echo "CSB_WARN:beads CLI install failed: ${NPM_ERROR:-timeout or unknown error}"
  echo "CSB_WARN:Diagnostics saved to $DIAG_LOG"
  echo "CSB_WARN:Install later with: npm install -g @beads/bd"
fi

# Skip plugin installation during provisioning - it doesn't persist properly
# Instead, install on first login via .bashrc
echo "CSB_PROGRESS:Configuring plugin installer"

# Auto-install plugins on first interactive login
cat >> ~/.bashrc << 'EOFRC'

# CSB first-run plugin installation
if [ ! -f ~/.csb-plugins-configured ] && [ -t 0 ]; then
  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Installing Claude plugins (first run)..."
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Initialize Claude (required for plugin commands to work)
  if ! claude --version > /dev/null 2>&1; then
    echo "  ERROR: Claude initialization failed, will retry on next login"
  else
    # Add marketplaces and install plugins
    claude plugin marketplace add steveyegge/beads 2>/dev/null || true
    claude plugin marketplace add obra/superpowers-marketplace 2>/dev/null || true
    claude plugin install beads@beads-marketplace 2>&1 || true
    claude plugin install superpowers@superpowers-marketplace 2>&1 || true

    # Mark as done
    touch ~/.csb-plugins-configured
    echo "  Done! Plugins installed."
  fi
  echo ""
fi
EOFRC

# Set workspace as default directory
echo 'cd /workspace' >> ~/.bashrc
