# Secure agent workspace — shared image for every project using this
# devcontainer. Nothing project-specific is baked in; PROJECT_NAME/GH_OWNER/
# APP_ID are supplied at container start via each project's own
# devcontainer.json (see /opt/agent-devcontainer/setup-agents.sh).
#
# Security model:
# - Only the workspace folder is bind-mounted (see devcontainer.json).
# - No host home dir, no ~/.ssh, no cloud credentials, no Docker socket.
# - Agent auth tokens are entered manually after start and live in
#   container-side named volumes, never on the host and never in the image.
FROM mcr.microsoft.com/devcontainers/base:ubuntu-24.04

# Base tooling
RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        gnupg \
        jq \
        ripgrep \
        tmux \
        unzip \
        zip \
    && rm -rf /var/lib/apt/lists/*

# Node.js 22 LTS — required by all three agent CLIs
RUN curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# GitHub CLI (official apt repository)
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# Issue Orchestrator package produced with `npm pack` from Sadotu/issue-orchestrator
# commit 6349c83929750b559965fbffb59fcd5eb35d2964 (package version 0.1.0).
# SHA-256 97b3f3881d1133dd77d8630fae8d5646ebadc819c1c9a805d3a223745cbcb035.
# Baked-in fallback only, same role as Claude Code/Codex below —
# setup-agents.sh shadows this at runtime with @sadotu/issue-orchestrator@latest
# from GitHub Packages (Sadotu/issue-orchestrator#81).
# Bump this vendored tarball (`bump-vendor.sh`) only occasionally now; it no
# longer gates day-to-day issue-orchestrator freshness.
COPY vendor/issue-orchestrator-6349c8392975.tgz /opt/agent-devcontainer/vendor/

# Agent CLIs — Claude Code, OpenAI Codex.
# Installed at build time (as root) as the baked-in fallback version.
# setup-agents.sh updates both at runtime into a separate vscode-owned npm
# prefix (~/.npm-global) instead — `--security-opt no-new-privileges`
# (devcontainer.json) disables sudo at runtime, and npm can't rewrite symlinks
# in root-owned /usr/bin without it even if the files themselves are chowned.
RUN npm install -g \
        @anthropic-ai/claude-code \
        @openai/codex \
        @bitwarden/cli \
        /opt/agent-devcontainer/vendor/issue-orchestrator-6349c8392975.tgz \
    && npm cache clean --force

# Explicit user command for issue orchestration. Defining this in Bash startup
# keeps image build and container startup inert.
COPY start-work.sh /etc/profile.d/start-work.sh
RUN printf '\nsource /etc/profile.d/start-work.sh\n' >> /etc/bash.bashrc

# Pre-create mount targets for the persisted config named volumes, owned by
# vscode. Docker seeds a named volume from the image path's content (incl.
# ownership) on first mount — without this the dir comes up root-owned and
# sudo can't fix it later, because runArgs sets --security-opt
# no-new-privileges, which disables sudo entirely.
RUN mkdir -p /home/vscode/.claude /home/vscode/.codex \
        /home/vscode/.config/gh /home/vscode/.config/github-app /home/vscode/.history \
    && chown -R vscode:vscode /home/vscode/.claude /home/vscode/.codex \
        /home/vscode/.config /home/vscode/.history

# setup-agents.sh runs as vscode and needs a writable location for its
# readiness marker. Keep /run itself root-owned; delegate only this directory.
RUN mkdir -p -m 0755 /run/agent-devcontainer \
    && chown vscode:vscode /run/agent-devcontainer

# Devcontainer tooling shared by every project — postCreateCommand in each
# project's thin devcontainer.json points here rather than at a per-project
# copy, so updates to these scripts ship by rebuilding this image.
COPY setup-agents.sh gh-app-token.sh git-credential-github-app.sh \
        codex-auth-sync.sh dotagents-install.sh \
        /opt/agent-devcontainer/
# Sourceable Bitwarden-session plumbing shared by setup-agents.sh and
# codex-auth-sync.sh (dc codex-push / codex-pull). Sourced, not executed.
COPY lib/bw-session.sh /opt/agent-devcontainer/lib/bw-session.sh
# Sourceable readiness-marker plumbing used by setup-agents.sh. Sourced, not
# executed — no chmod +x needed (same as bw-session.sh).
COPY lib/setup-marker.sh /opt/agent-devcontainer/lib/setup-marker.sh
COPY githooks/pre-push /opt/agent-devcontainer/githooks/pre-push
COPY agents.toml /opt/agent-devcontainer/agents.toml
COPY claude-settings.json /opt/agent-devcontainer/claude-settings.json
RUN chmod +x /opt/agent-devcontainer/setup-agents.sh \
        /opt/agent-devcontainer/gh-app-token.sh \
        /opt/agent-devcontainer/git-credential-github-app.sh \
        /opt/agent-devcontainer/codex-auth-sync.sh \
        /opt/agent-devcontainer/dotagents-install.sh \
        /opt/agent-devcontainer/githooks/pre-push

# Project scaffolder + the two per-project files it emits.
# `dc` and devcontainer.json must exist in a project BEFORE any container can
# be created, so they can't be produced by the devcontainer lifecycle. Instead
# `init` (run via a plain `docker run ... init`, outside that lifecycle) writes
# them into a bind-mounted project. Baking `dc` here as the canonical template
# also makes it the single source of truth — no more copying it verbatim.
# `init` is a normal script on PATH, NOT an ENTRYPOINT, so the container-start
# path stays completely untouched.
COPY dc /opt/agent-devcontainer/templates/dc
COPY devcontainer.json.template /opt/agent-devcontainer/templates/devcontainer.json.template
COPY init.sh /usr/local/bin/init
RUN chmod 0755 /usr/local/bin/init \
        && chmod 0755 /opt/agent-devcontainer/templates/dc

# Image version identifier (issue #24). Tied unambiguously to the built image:
# IMAGE_VERSION is the Git commit SHA the publish workflow passes, identical to
# the published `:<sha>` tag. Declared here — after every heavy install layer —
# so a changing SHA only rebuilds this cheap final layer, not apt/npm caches.
# Local dogfood builds (devcontainer.json `build:`, no build-args) fall back to
# `dev`/`unknown`; only published CI builds carry a real SHA.
ARG IMAGE_VERSION=dev
ARG IMAGE_BUILD_DATE=unknown
LABEL org.opencontainers.image.revision="${IMAGE_VERSION}" \
      org.opencontainers.image.created="${IMAGE_BUILD_DATE}" \
      org.opencontainers.image.source="https://github.com/Sadotu/agent-devcontainer"
RUN printf 'agent-devcontainer image\nversion: %s\nbuilt:   %s\n' \
        "$IMAGE_VERSION" "$IMAGE_BUILD_DATE" > /opt/agent-devcontainer/VERSION
COPY version.sh /usr/local/bin/agent-devcontainer-version
RUN chmod 0755 /usr/local/bin/agent-devcontainer-version
