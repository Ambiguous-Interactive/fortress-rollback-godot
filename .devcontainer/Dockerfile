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

# Modern CLI tooling for humans and agents, in a single layer. Ubuntu ships
# fd and bat under different names; symlinks restore the conventional ones.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bat \
        fd-find \
        fzf \
        jq \
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

# uv: official static binaries from the pinned release image (see uv-bin stage).
COPY --from=uv-bin /uv /uvx /usr/local/bin/
