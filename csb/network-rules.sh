#!/bin/bash
# Network allowlist for Claude Sandbox
# Blocks all outbound traffic except approved domains

set -e

# Allowed domains organized by category
ALLOWED_DOMAINS=(
    # Package managers
    "pypi.org"
    "files.pythonhosted.org"
    "registry.npmjs.org"
    "crates.io"
    "static.crates.io"
    "rubygems.org"
    "proxy.golang.org"
    "sum.golang.org"

    # Code hosting
    "github.com"
    "api.github.com"
    "raw.githubusercontent.com"
    "objects.githubusercontent.com"
    "codeload.github.com"
    "gitlab.com"
    "bitbucket.org"

    # Claude / Anthropic
    "api.anthropic.com"
    "console.anthropic.com"
    "statsig.anthropic.com"

    # DNS (required for resolution)
    "dns.google"

    # Debian package repos (for apt)
    "deb.debian.org"
    "security.debian.org"
    "cdn-fastly.deb.debian.org"

    # Node.js
    "nodejs.org"
    "registry.yarnpkg.com"

    # Cloud images (for Lima)
    "cloud.debian.org"
)

# Resolve domain to IPs and add iptables rules
resolve_and_allow() {
    local domain="$1"
    local ips

    # Resolve domain to IP addresses
    ips=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.' || true)
    ips+=$'\n'$(dig +short "$domain" AAAA 2>/dev/null | grep -E '^[0-9a-f:]+' || true)

    for ip in $ips; do
        if [[ -n "$ip" && "$ip" != *";"* ]]; then
            # Allow outbound to this IP
            iptables -A OUTPUT -d "$ip" -j ACCEPT 2>/dev/null || true
            ip6tables -A OUTPUT -d "$ip" -j ACCEPT 2>/dev/null || true
        fi
    done
}

echo "Configuring network allowlist..."

# Flush existing rules
iptables -F OUTPUT 2>/dev/null || true
ip6tables -F OUTPUT 2>/dev/null || true

# Allow loopback
iptables -A OUTPUT -o lo -j ACCEPT
ip6tables -A OUTPUT -o lo -j ACCEPT

# Allow established connections
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow DNS (UDP and TCP port 53)
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
ip6tables -A OUTPUT -p udp --dport 53 -j ACCEPT
ip6tables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# Allow DHCP
iptables -A OUTPUT -p udp --dport 67:68 -j ACCEPT
ip6tables -A OUTPUT -p udp --dport 67:68 -j ACCEPT

# Allow NTP (time sync)
iptables -A OUTPUT -p udp --dport 123 -j ACCEPT
ip6tables -A OUTPUT -p udp --dport 123 -j ACCEPT

# Resolve and allow each domain
for domain in "${ALLOWED_DOMAINS[@]}"; do
    echo "  Allowing: $domain"
    resolve_and_allow "$domain"
done

# Drop everything else
iptables -A OUTPUT -j DROP
ip6tables -A OUTPUT -j DROP

echo "Network allowlist configured. Only approved domains are accessible."

# Save rules to persist across reboots
if command -v iptables-save &> /dev/null; then
    iptables-save > /etc/iptables.rules 2>/dev/null || true
    ip6tables-save > /etc/ip6tables.rules 2>/dev/null || true

    # Create systemd service to restore rules on boot
    cat > /etc/systemd/system/iptables-restore.service << 'EOF'
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
EOF

    systemctl daemon-reload 2>/dev/null || true
    systemctl enable iptables-restore.service 2>/dev/null || true
fi

echo "Done."
