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
# commit bb48f1c5f54eda3881cec68020524ff83139ee7c (package version 0.1.0).
COPY vendor/issue-orchestrator-bb48f1c5f54e.tgz /opt/agent-devcontainer/vendor/

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
        /opt/agent-devcontainer/vendor/issue-orchestrator-bb48f1c5f54e.tgz \
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

# Devcontainer tooling shared by every project — postCreateCommand in each
# project's thin devcontainer.json points here rather than at a per-project
# copy, so updates to these scripts ship by rebuilding this image.
COPY setup-agents.sh gh-app-token.sh git-credential-github-app.sh \
        /opt/agent-devcontainer/
COPY githooks/pre-push /opt/agent-devcontainer/githooks/pre-push
COPY agents.toml /opt/agent-devcontainer/agents.toml
RUN chmod +x /opt/agent-devcontainer/setup-agents.sh \
        /opt/agent-devcontainer/gh-app-token.sh \
        /opt/agent-devcontainer/git-credential-github-app.sh \
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
