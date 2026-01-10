#!/bin/bash
# Install Claude Code plugins
# Run this after Claude has been initialized at least once

set -e

export PATH="$HOME/.npm-global/bin:$PATH"

echo "Installing Claude Code plugins..."

# Initialize Claude first
echo "  Initializing Claude..."
claude --version

# Add marketplaces
echo "  Adding marketplaces..."
claude plugin marketplace add steveyegge/beads || echo "  (beads marketplace may already exist)"
claude plugin marketplace add obra/superpowers-marketplace || echo "  (superpowers marketplace may already exist)"

# Install plugins
echo "  Installing plugins..."
claude plugin install beads@beads-marketplace
claude plugin install superpowers@superpowers-marketplace

# Verify
echo ""
echo "Verifying installation..."
if grep -q "beads@beads-marketplace" ~/.claude/plugins/installed_plugins.json && \
   grep -q "superpowers@superpowers-marketplace" ~/.claude/plugins/installed_plugins.json; then
  echo "SUCCESS: Both plugins installed"
  touch ~/.csb-plugins-configured
else
  echo "FAILED: Plugins not found in installed_plugins.json"
  exit 1
fi
