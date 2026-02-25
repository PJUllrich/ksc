#!/bin/bash
set -euo pipefail
IFS=$'\n\t'

# ============================================================================
# Tinyproxy forward proxy firewall
#
# Blocks direct HTTP/HTTPS traffic, forcing it through the tinyproxy forward
# proxy (via HTTP_PROXY/HTTPS_PROXY env vars). Tinyproxy filters by domain
# using the allowed-domains.txt whitelist. Non-web traffic (DNS, localhost,
# host network) is handled directly by iptables.
# ============================================================================

# --- Preserve Docker internal DNS before flushing ---
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

# --- Flush all existing rules ---
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X

# --- Restore Docker DNS ---
if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# --- Expand allowed-domains.txt into tinyproxy fnmatch format ---
# Input format (squid-style):
#   .github.com        -> matches github.com, *.github.com, and all with :port
#   storage.google.com -> matches storage.google.com and storage.google.com:port
ALLOWED="/usr/local/etc/allowed-domains.txt"
EXPANDED="/tmp/allowed-domains-expanded.txt"
> "$EXPANDED"
while IFS= read -r line; do
    # Skip comments and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    if [[ "$line" == .* ]]; then
        # .domain.com -> match bare domain and subdomains, with and without port
        bare="${line#.}"
        echo "$bare" >> "$EXPANDED"
        echo "$bare:*" >> "$EXPANDED"
        echo "*$line" >> "$EXPANDED"
        echo "*$line:*" >> "$EXPANDED"
    else
        # exact domain
        echo "$line" >> "$EXPANDED"
        echo "$line:*" >> "$EXPANDED"
    fi
done < "$ALLOWED"
# Point tinyproxy at the expanded file
sed -i "s|^Filter .*|Filter \"$EXPANDED\"|" /etc/tinyproxy/tinyproxy.conf

# --- Stop existing tinyproxy if running ---
if [ -f /run/tinyproxy/tinyproxy.pid ]; then
    kill "$(cat /run/tinyproxy/tinyproxy.pid)" 2>/dev/null || true
    rm -f /run/tinyproxy/tinyproxy.pid
    sleep 1
fi

# --- Start tinyproxy (before DROP policies, so it can initialize) ---
mkdir -p /run/tinyproxy /var/log/tinyproxy
chown -R nobody:nogroup /run/tinyproxy /var/log/tinyproxy

echo "Starting tinyproxy..."
tinyproxy -c /etc/tinyproxy/tinyproxy.conf
sleep 1

if [ ! -f /run/tinyproxy/tinyproxy.pid ] || ! kill -0 "$(cat /run/tinyproxy/tinyproxy.pid)" 2>/dev/null; then
    echo "ERROR: tinyproxy failed to start. Check /var/log/tinyproxy/tinyproxy.log"
    cat /var/log/tinyproxy/tinyproxy.log 2>/dev/null || true
    exit 1
fi
echo "Tinyproxy started"

# --- Base allow rules ---

# Allow loopback
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# Allow DNS (needed for tinyproxy to resolve domains)
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT

# Allow established/related connections
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow host network (VS Code, Docker comms)
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi
HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network: $HOST_NETWORK"
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# --- Tinyproxy forward proxy rules ---

# Allow tinyproxy (nobody user) to make outbound HTTP/HTTPS connections
iptables -A OUTPUT -p tcp --dport 80 -m owner --uid-owner nobody -j ACCEPT
iptables -A OUTPUT -p tcp --dport 443 -m owner --uid-owner nobody -j ACCEPT

# Block direct outbound HTTP/HTTPS from all other users
# (forces traffic through tinyproxy via HTTP_PROXY/HTTPS_PROXY env vars)
iptables -A OUTPUT -p tcp --dport 80 -j REJECT --reject-with icmp-admin-prohibited
iptables -A OUTPUT -p tcp --dport 443 -j REJECT --reject-with icmp-admin-prohibited

# --- Set default DROP policy ---
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Explicit reject for clear error messages on non-allowed traffic
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# --- Verification ---
echo "Verifying firewall rules..."
if curl --proxy http://localhost:3128 --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com"
    exit 1
else
    echo "PASS: example.com blocked"
fi

if ! curl --proxy http://localhost:3128 --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
    exit 1
else
    echo "PASS: api.github.com reachable"
fi

if ! curl --proxy http://localhost:3128 --connect-timeout 5 https://claude.ai >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://claude.ai"
    exit 1
else
    echo "PASS: claude.ai reachable"
fi

echo "Firewall configuration complete"
