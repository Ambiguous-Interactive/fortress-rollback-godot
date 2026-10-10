#!/usr/bin/env bash
# OPTIONAL egress firewall for agentic sandboxing (OFF by default).
#
# Adapted from Anthropic's reference devcontainer:
# https://github.com/anthropics/claude-code (`.devcontainer/init-firewall.sh`)
#
# Blocks all container egress except an allowlist of domains needed by this
# project's agents: LLM providers (Anthropic, z.ai, OpenRouter), GitHub,
# package/tool sources (npm, PyPI, astral.sh, opencode.ai), VS Code updates,
# and Godot (godotengine.org, Context7 docs).
#
# To enable, make these three changes in .devcontainer/devcontainer.json:
#   1. "runArgs": add "--cap-add=NET_ADMIN" and "--cap-add=NET_RAW"
#   2. add "postStartCommand": "sudo bash .devcontainer/init-firewall.sh"
#   3. rebuild the container
#
# The script self-installs its dependencies on first run (they are kept out
# of the base image because the firewall is opt-in).
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "must run as root (postStartCommand uses sudo)" >&2
    exit 1
fi

echo "[firewall] installing dependencies"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ipset iptables dnsutils
rm -rf /var/lib/apt/lists/*

# Domains agents and tooling need. GitHub CIDRs are fetched dynamically below.
ALLOWED_DOMAINS=(
    "registry.npmjs.org"
    "api.anthropic.com"
    "console.anthropic.com"
    "statsig.anthropic.com"
    "sentry.io"
    "api.z.ai"
    "openrouter.ai"
    "api.githubcopilot.com"
    "mcp.context7.com"
    "context7.com"
    "opencode.ai"
    "pypi.org"
    "files.pythonhosted.org"
    "astral.sh"
    "godotengine.org"
    "marketplace.visualstudio.com"
    "vscode.blob.core.windows.net"
    "update.code.visualstudio.com"
)

# 1. Preserve Docker's embedded DNS NAT rules before flushing.
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "[firewall] restoring Docker DNS rules"
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
fi

# 2. Baseline allows: DNS, SSH, localhost.
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# 3. Allowlist.
ipset create allowed-domains hash:net

echo "[firewall] fetching GitHub IP ranges"
gh_ranges=$(curl -fsS https://api.github.com/meta)
if ! echo "$gh_ranges" | jq -e '.web and .api and .git and .packages' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields" >&2
    exit 1
fi
# The meta endpoint contains duplicates across sections; ipset add fails on
# duplicates and would abort the script mid-apply (fail-open), so dedupe.
while read -r cidr; do
    ipset add allowed-domains "$cidr" 2>/dev/null || true
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git + .packages)[]' | sort -u)

for domain in "${ALLOWED_DOMAINS[@]}"; do
    echo "[firewall] resolving ${domain}"
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        echo "ERROR: failed to resolve ${domain}" >&2
        exit 1
    fi
    while read -r ip; do
        ipset add allowed-domains "$ip" 2>/dev/null || true
    done <<<"$ips"
done

# 4. Host network (Docker Desktop socket proxy, host services).
HOST_IP=$(ip route | grep default | head -n1 | cut -d" " -f3)
HOST_NETWORK=$(echo "$HOST_IP" | sed 's/\.[0-9]*$/.0\/24/')
echo "[firewall] allowing host network ${HOST_NETWORK}"
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# 5. Default DROP + allow established + allowlist + explicit REJECT.
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# 6. IPv6: the allowlist above is IPv4-only. Block IPv6 egress entirely
# (except loopback/established/ICMPv6) so blocked domains cannot be reached
# over a parallel IPv6 route — fail closed instead of fail open.
ip6tables -F
ip6tables -X 2>/dev/null || true
ip6tables -P INPUT DROP
ip6tables -P FORWARD DROP
ip6tables -P OUTPUT DROP
ip6tables -A INPUT -i lo -j ACCEPT
ip6tables -A OUTPUT -o lo -j ACCEPT
ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
ip6tables -A OUTPUT -p ipv6-icmp -j ACCEPT

echo "[firewall] verifying"
if curl --connect-timeout 5 https://example.com >/dev/null 2>&1; then
    echo "ERROR: firewall verification failed - reached example.com" >&2
    exit 1
fi
if ! curl --connect-timeout 5 https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: firewall verification failed - cannot reach api.github.com" >&2
    exit 1
fi
echo "[firewall] active: allowlist enforced, GitHub reachable, generic egress blocked"
