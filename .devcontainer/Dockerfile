# syntax=docker/dockerfile:1
# Fortress Rollback Godot devcontainer.
#
# Design goals, in order:
#   1. Fast rebuilds: one apt layer, pinned versions, everything cacheable.
#   2. Stability: pinned Godot + uv; agentic CLIs track latest by design.
#   3. Small surface: no secrets baked in; optional tooling stays out.

ARG BASE_IMAGE=mcr.microsoft.com/devcontainers/base:ubuntu-24.04
# uv is pinned; it is infrastructure, not a fast-moving agent CLI.
# BuildKit does not expand ARGs in `COPY --from`, so the uv image is pulled in
# through a dedicated stage below.
ARG UV_VERSION=0.13.0

FROM ghcr.io/astral-sh/uv:${UV_VERSION} AS uv-bin

FROM ${BASE_IMAGE}

# Engine version is pinned for deterministic harness behavior (replays,
# checksums). Bump via devcontainer.json build args, not by editing layers.
ARG GODOT_VERSION=4.7.2-stable
# BuildKit predefined arg; must be (re)declared to be visible in RUN.
ARG TARGETARCH
# Node LTS, pinned: it runs the MCP servers, so its presence must not depend
# on feature ordering. Installed before features run (the claude-code feature
# detects and reuses it).
ARG NODE_VERSION=22.23.3

# Modern CLI tooling for humans and agents, in a single layer. Ubuntu ships
# fd and bat under different names; symlinks restore the conventional ones.
# python3 must be the FULL package: the base image ships none, and features
# install only python3-minimal, which lacks stdlib modules (json, unittest,
# dataclasses) that this repo's harness requires.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bat \
        fd-find \
        fzf \
        jq \
        python3 \
        ripgrep \
        tree \
        unzip \
        xz-utils \
    && rm -rf /var/lib/apt/lists/* \
    && ln -s "$(command -v fdfind)" /usr/local/bin/fd \
    && ln -s "$(command -v batcat)" /usr/local/bin/bat

# Godot official build. Docker amd64/arm64 -> Godot x86_64/arm64.
RUN case "${TARGETARCH}" in \
        amd64) godot_arch=x86_64 ;; \
        arm64) godot_arch=arm64 ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL -o /tmp/godot.zip \
        "https://github.com/godotengine/godot/releases/download/${GODOT_VERSION}/Godot_v${GODOT_VERSION}_linux.${godot_arch}.zip" \
    && unzip -q /tmp/godot.zip -d /tmp/godot \
    && install -m 0755 "/tmp/godot/Godot_v${GODOT_VERSION}_linux.${godot_arch}" /usr/local/bin/godot \
    && rm -rf /tmp/godot /tmp/godot.zip \
    && godot --version

# Pre-create persistent-volume mount points owned by the container user.
# Without this, Docker creates missing mount-point parents as root and the
# remote user cannot write into the freshly mounted volumes.
RUN mkdir -p /home/vscode/.claude \
             /home/vscode/.cache/uv \
             /home/vscode/.local/share/opencode \
             /home/vscode/.local/share/godot \
             /home/vscode/.commandhistory \
    && chown -R vscode:vscode /home/vscode

# OpenCode: official release tarball (latest). The official install script
# queries the unauthenticated GitHub API, which is rate-limited during
# container builds, so fetch the release asset directly (a plain download,
# no API call). glibc non-musl, non-baseline build; arch-aware like Godot.
RUN case "${TARGETARCH}" in \
        amd64) opencode_arch=x64 ;; \
        arm64) opencode_arch=arm64 ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL -o /tmp/opencode.tar.gz \
        "https://github.com/anomalyco/opencode/releases/latest/download/opencode-linux-${opencode_arch}.tar.gz" \
    && tar -xzf /tmp/opencode.tar.gz -C /tmp \
    && install -m 0755 /tmp/opencode /usr/local/bin/opencode \
    && rm -rf /tmp/opencode /tmp/opencode.tar.gz \
    && opencode --version

# Node.js: official pinned tarball into /usr/local (bin, lib, share).
RUN case "${TARGETARCH}" in \
        amd64) node_arch=x64 ;; \
        arm64) node_arch=arm64 ;; \
        *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL -o /tmp/node.tar.xz \
        "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" \
    && tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 --no-same-owner \
    && rm /tmp/node.tar.xz \
    && node --version && npm --version

# godot-mcp server: installed globally and pinned so container creation and
# MCP sessions never depend on npm registry uptime (npx resolves the global
# package first; the committed MCP configs keep `npx -y` for portability
# outside this container).
RUN npm install -g "@coding-solo/godot-mcp@0.1.1" \
    && godot-mcp --help >/dev/null 2>&1 || true

# uv: official static binaries from the pinned release image (see uv-bin stage).
COPY --from=uv-bin /uv /uvx /usr/local/bin/
