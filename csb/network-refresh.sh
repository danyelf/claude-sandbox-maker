#!/bin/bash
# Refresh IP addresses for allowed domains
# Called periodically by systemd timer to handle CDN IP rotation
#
# This script re-resolves all domains and adds new IPs to the ipsets.
# Old IPs are retained (ipset ignores duplicates) - the sets accumulate
# IPs over time. This is intentional: CDN connections may persist after
# DNS changes, so we don't want to break existing connections.

set -e

DOMAIN_FILE="/etc/csb-allowed-domains.txt"
LOG_TAG="csb-network-refresh"

log() {
    logger -t "$LOG_TAG" "$1"
}

if [[ ! -f "$DOMAIN_FILE" ]]; then
    log "Domain file not found: $DOMAIN_FILE"
    exit 1
fi

# Ensure ipsets exist (they should, but be defensive)
if ! ipset list csb-allowed-v4 &>/dev/null; then
    ipset create csb-allowed-v4 hash:ip family inet hashsize 1024 maxelem 65536
fi
if ! ipset list csb-allowed-v6 &>/dev/null; then
    ipset create csb-allowed-v6 hash:ip family inet6 hashsize 1024 maxelem 65536
fi

added_v4=0
added_v6=0

while IFS= read -r domain || [[ -n "$domain" ]]; do
    [[ -z "$domain" || "$domain" =~ ^# ]] && continue

    # Resolve IPv4 addresses
    ips=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.' || true)
    for ip in $ips; do
        if [[ -n "$ip" && "$ip" != *";"* ]]; then
            if ipset add csb-allowed-v4 "$ip" 2>/dev/null; then
                ((added_v4++)) || true
            fi
        fi
    done

    # Resolve IPv6 addresses
    ips=$(dig +short "$domain" AAAA 2>/dev/null | grep -E '^[0-9a-f:]+' || true)
    for ip in $ips; do
        if [[ -n "$ip" && "$ip" != *";"* ]]; then
            if ipset add csb-allowed-v6 "$ip" 2>/dev/null; then
                ((added_v6++)) || true
            fi
        fi
    done
done < "$DOMAIN_FILE"

# Save updated ipsets
ipset save > /etc/ipset.rules 2>/dev/null || true

if [[ $added_v4 -gt 0 || $added_v6 -gt 0 ]]; then
    log "Added $added_v4 IPv4 and $added_v6 IPv6 addresses"
else
    log "No new IPs discovered"
fi
