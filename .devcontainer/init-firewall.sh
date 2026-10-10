#!/usr/bin/env bash
# OPTIONAL egress firewall for agentic sandboxing (OFF by default).
#
# Adapted from Anthropic's reference devcontainer:
# https://github.com/anthropics/claude-code (`.devcontainer/init-firewall.sh`)
#
# Blocks all container egress except an allowlist of domains needed by this
# project's agents: LLM providers (Anthropic, z.ai, OpenRouter), GitHub,
# package/tool sources (npm, PyPI, astral.sh, opencode.ai, nodejs.org), VS Code
# updates and extension downloads, and Godot (godotengine.org, Context7 docs).
#
# To enable, make these three changes in .devcontainer/devcontainer.json:
#   1. "runArgs": add "--cap-add=NET_ADMIN" and "--cap-add=NET_RAW"
#   2. add "postStartCommand": "sudo bash .devcontainer/init-firewall.sh"
#   3. rebuild the container
#
# Fail-closed contract: ALL network-dependent work (fetches, DNS resolution)
# happens BEFORE the firewall is torn down. The flush and the DROP policies
# are applied back-to-back with no network calls in between, so a mid-setup
# failure can only leave the previous state — never a flushed, open one.
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
    "claude.ai"
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
    "nodejs.org"
    "godotengine.org"
    "marketplace.visualstudio.com"
    "vscode.blob.core.windows.net"
    "update.code.visualstudio.com"
    "gallery.vsassets.io"
    "vscode.download.prss.microsoft.com"
)

# ── Phase A: gather everything the rules need (no mutations yet) ────────

echo "[firewall] fetching GitHub IP ranges"
gh_ranges=$(curl -fsS https://api.github.com/meta)
if ! echo "$gh_ranges" | jq -e '.web and .api and .git and .packages' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields" >&2
    exit 1
fi
# The meta endpoint contains duplicates across sections; dedupe so the apply
# phase never trips over them.
mapfile -t GH_CIDRS < <(echo "$gh_ranges" | jq -r '(.web + .api + .git + .packages)[]' | sort -u)

DOMAIN_IPS="$(mktemp)"
trap 'rm -f "$DOMAIN_IPS"' EXIT
for domain in "${ALLOWED_DOMAINS[@]}"; do
    echo "[firewall] resolving ${domain}"
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        echo "ERROR: failed to resolve ${domain}" >&2
        exit 1
    fi
    printf '%s\n' "$ips" >>"$DOMAIN_IPS"
done

host_ip="$(ip route | grep default | head -n1 | cut -d' ' -f3 || true)"
if [ -z "$host_ip" ]; then
    echo "ERROR: no default route detected" >&2
    exit 1
fi
HOST_NETWORK="$(echo "$host_ip" | sed 's/\.[0-9]*$/.0\/24/')"

docker_dns_rules="$(iptables-save -t nat | grep '127\.0\.0\.11' || true)"

# ── Phase B: apply (flush → policies back-to-back, no network calls) ────

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

if [ -n "$docker_dns_rules" ]; then
    echo "[firewall] restoring Docker DNS rules"
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$docker_dns_rules" | xargs -L 1 iptables -t nat
fi

# Policies FIRST: from this instant the container is closed, so any later
# failure fails closed.
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# Baseline allows: DNS (udp+tcp; large answers retry over TCP), SSH, localhost.
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT
iptables -A INPUT -p udp --sport 53 -j ACCEPT
iptables -A INPUT -p tcp --sport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --sport 22 -m state --state ESTABLISHED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# Allowlist.
ipset create allowed-domains hash:net
for cidr in "${GH_CIDRS[@]}"; do
    ipset add allowed-domains "$cidr" 2>/dev/null || true
done
while read -r ip; do
    ipset add allowed-domains "$ip" 2>/dev/null || true
done <"$DOMAIN_IPS"

iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# IPv6: the allowlist above is IPv4-only. Block IPv6 egress entirely
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
