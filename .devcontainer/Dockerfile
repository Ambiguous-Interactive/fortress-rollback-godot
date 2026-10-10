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
             /home/vscode/.codex \
             /home/vscode/.commandhistory \
    && chown -R vscode:vscode /home/vscode

# Agentic CLIs use global npm installs after Node lands below. Their packages
# select the native binaries for the build architecture.

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

# OpenCode v2 uses the @opencode/cli package. Check the installed major so
# a future package-channel change cannot silently install another version.

RUN npm install -g "@opencode/cli@latest" \
    && opencode --version \
    && node -e 'const v=require("/usr/local/lib/node_modules/@opencode/cli/package.json").version; \
        if(!v.startsWith("2.")) {console.error("expected OpenCode v2, got "+v); process.exit(1)}'

# Codex CLI (latest), using the global npm layout checked by verify-tools.sh.
# Check the package root offline without parsing human-readable diagnostics.

RUN npm install -g "@openai/codex@latest" \
    && codex --version \
    && test -f "$(npm root -g)/@openai/codex/package.json"

# godot-mcp server: installed globally and pinned so MCP sessions never
# depend on npm registry uptime or version drift. The committed MCP configs
# invoke the `godot-mcp` binary directly (note: `npx -y` does NOT resolve
# global installs, so configs must not use npx). The configs assume this
# devcontainer (they also hardcode the container's Godot path); outside it,
# install the package manually: npm i -g @coding-solo/godot-mcp@0.1.1
RUN npm install -g "@coding-solo/godot-mcp@0.1.1" \
    && npm ls -g --depth=0 "@coding-solo/godot-mcp" \
    && command -v godot-mcp

# uv: official static binaries from the pinned release image (see uv-bin stage).
COPY --from=uv-bin /uv /uvx /usr/local/bin/
