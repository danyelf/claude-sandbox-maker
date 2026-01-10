#!/bin/bash
# shellcheck shell=bash
set -eux -o pipefail

# Configure network restrictions for Claude Sandbox
# - DNS-based domain allowlist via dnsmasq
# - iptables firewall rules

echo "CSB_PROGRESS:Applying network restrictions"

# =============================================================
# Git credentials for HTTPS authentication
# Enables all users (including parallel agents) to push/pull via HTTPS
# =============================================================
if [[ -n "${GITHUB_TOKEN:-}" ]]; then
    echo "Configuring git credentials..."
    mkdir -p /etc/csb
    echo "https://oauth2:${GITHUB_TOKEN}@github.com" > /etc/csb/git-credentials
    chmod 644 /etc/csb/git-credentials
    git config --system credential.helper "store --file=/etc/csb/git-credentials"
    echo "Git credentials configured for HTTPS authentication"
fi

# =============================================================
# DNS-based domain allowlist for Claude Sandbox
#
# Strategy: Use dnsmasq to only resolve allowed domains.
# Unknown domains return NXDOMAIN, so connections fail at DNS.
# iptables blocks external DNS and allows HTTP/HTTPS to anywhere
# (since only allowed domains can be resolved).
# =============================================================

# Path to allowed domains list (injected during build)
ALLOWED_DOMAINS_FILE="${ALLOWED_DOMAINS_FILE:-/opt/csb/allowed-domains.txt}"

# Generate dnsmasq config from allowed domains list
generate_dnsmasq_config() {
    cat << 'EOF'
# CSB Domain Allowlist (auto-generated)
# Only these domains (and their subdomains) can be resolved

# Don't use /etc/resolv.conf (we'll set upstream separately)
no-resolv

# Upstream DNS servers (only used for allowed domains)
server=8.8.8.8
server=8.8.4.4

# Block everything by default (return NXDOMAIN)
address=/#/

# === ALLOWED DOMAINS ===
EOF

    # Read domains from config file, skip comments and empty lines
    if [[ -f "$ALLOWED_DOMAINS_FILE" ]]; then
        while IFS= read -r line || [[ -n "$line" ]]; do
            # Skip comments and empty lines
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line// }" ]] && continue
            # Output dnsmasq server directive
            echo "server=/${line}/8.8.8.8"
        done < "$ALLOWED_DOMAINS_FILE"
    else
        echo "# WARNING: $ALLOWED_DOMAINS_FILE not found, no domains allowed" >&2
    fi
}

# Configure dnsmasq as local DNS resolver with domain allowlist
generate_dnsmasq_config > /etc/dnsmasq.d/csb-allowlist.conf

# Stop dnsmasq if running, configure, and restart
systemctl stop dnsmasq 2>/dev/null || true

# Point system DNS to local dnsmasq
# Use resolvconf if available, otherwise write directly
if command -v resolvconf &> /dev/null; then
    echo "nameserver 127.0.0.1" | resolvconf -a lo.dnsmasq
else
    # Backup original and write new resolv.conf
    cp /etc/resolv.conf /etc/resolv.conf.backup 2>/dev/null || true
    echo "nameserver 127.0.0.1" > /etc/resolv.conf
fi

# Start dnsmasq
systemctl enable dnsmasq
systemctl start dnsmasq

echo "DNS allowlist configured via dnsmasq"

# === iptables rules ===
# Block external DNS, allow HTTP/HTTPS to anywhere
# (DNS filtering handles domain restrictions)

# Helper: add iptables OUTPUT rule for both IPv4 and IPv6
allow_output() {
    iptables -A OUTPUT "$@" 2>/dev/null || true
    ip6tables -A OUTPUT "$@" 2>/dev/null || true
}

echo "Configuring iptables..."

# Flush existing OUTPUT rules
iptables -F OUTPUT 2>/dev/null || true
ip6tables -F OUTPUT 2>/dev/null || true

# Allow loopback (includes local DNS)
allow_output -o lo -j ACCEPT

# Allow established connections
allow_output -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow DNS only to localhost (dnsmasq)
# Block external DNS to prevent bypassing the allowlist
allow_output -p udp --dport 53 -d 127.0.0.1 -j ACCEPT
allow_output -p tcp --dport 53 -d 127.0.0.1 -j ACCEPT
allow_output -p udp --dport 53 -j DROP
allow_output -p tcp --dport 53 -j DROP

# Allow DHCP (needed for Lima networking)
allow_output -p udp --dport 67:68 -j ACCEPT

# Allow NTP (time sync)
allow_output -p udp --dport 123 -j ACCEPT

# Allow HTTP/HTTPS to anywhere (DNS filtering handles restrictions)
allow_output -p tcp --dport 80 -j ACCEPT
allow_output -p tcp --dport 443 -j ACCEPT

# Allow git protocol (some repos use this)
allow_output -p tcp --dport 9418 -j ACCEPT

# Allow SSH (for git clone via SSH)
allow_output -p tcp --dport 22 -j ACCEPT

# Drop everything else
allow_output -j DROP

echo "iptables configured"

# Save rules to persist across reboots
iptables-save > /etc/iptables.rules 2>/dev/null || true
ip6tables-save > /etc/ip6tables.rules 2>/dev/null || true

cat > /etc/systemd/system/iptables-restore.service << 'EOFSERVICE'
[Unit]
Description=Restore iptables rules
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore /etc/iptables.rules
ExecStart=/sbin/ip6tables-restore /etc/ip6tables.rules
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOFSERVICE

systemctl daemon-reload 2>/dev/null || true
systemctl enable iptables-restore.service 2>/dev/null || true

echo "CSB_PROGRESS:Setup complete"
echo "Network restrictions configured (DNS-based allowlist + iptables)"
