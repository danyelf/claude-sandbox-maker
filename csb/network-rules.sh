#!/bin/bash
# Network allowlist for Claude Sandbox
# Uses ipset for efficient IP matching with periodic refresh
#
# This script sets up the initial firewall rules using ipset.
# A systemd timer runs network-refresh.sh periodically to update IPs
# as CDN endpoints rotate.

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

# Export domains for use by refresh script
export_domains() {
    printf '%s\n' "${ALLOWED_DOMAINS[@]}" > /etc/csb-allowed-domains.txt
}

# Create ipsets if they don't exist
create_ipsets() {
    # IPv4 set
    if ! ipset list csb-allowed-v4 &>/dev/null; then
        ipset create csb-allowed-v4 hash:ip family inet hashsize 1024 maxelem 65536
    fi
    # IPv6 set
    if ! ipset list csb-allowed-v6 &>/dev/null; then
        ipset create csb-allowed-v6 hash:ip family inet6 hashsize 1024 maxelem 65536
    fi
}

# Resolve domain to IPs and add to ipset
resolve_and_add() {
    local domain="$1"
    local ips

    # Resolve IPv4 addresses
    ips=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.' || true)
    for ip in $ips; do
        if [[ -n "$ip" && "$ip" != *";"* ]]; then
            ipset add csb-allowed-v4 "$ip" 2>/dev/null || true
        fi
    done

    # Resolve IPv6 addresses
    ips=$(dig +short "$domain" AAAA 2>/dev/null | grep -E '^[0-9a-f:]+' || true)
    for ip in $ips; do
        if [[ -n "$ip" && "$ip" != *";"* ]]; then
            ipset add csb-allowed-v6 "$ip" 2>/dev/null || true
        fi
    done
}

echo "Configuring network allowlist with ipset..."

# Export domain list for refresh script
export_domains

# Create ipsets
create_ipsets

# Populate ipsets with resolved IPs
for domain in "${ALLOWED_DOMAINS[@]}"; do
    echo "  Resolving: $domain"
    resolve_and_add "$domain"
done

# Flush existing OUTPUT rules
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

# Allow traffic to IPs in our ipsets
iptables -A OUTPUT -m set --match-set csb-allowed-v4 dst -j ACCEPT
ip6tables -A OUTPUT -m set --match-set csb-allowed-v6 dst -j ACCEPT

# Drop everything else
iptables -A OUTPUT -j DROP
ip6tables -A OUTPUT -j DROP

echo "Network allowlist configured with ipset."

# Save ipsets and rules to persist across reboots
ipset save > /etc/ipset.rules 2>/dev/null || true
iptables-save > /etc/iptables.rules 2>/dev/null || true
ip6tables-save > /etc/ip6tables.rules 2>/dev/null || true

echo "Done. IPs will be refreshed periodically by csb-network-refresh.timer"
