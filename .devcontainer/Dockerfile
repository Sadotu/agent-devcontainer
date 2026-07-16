# __PROJECT_NAME__ secure agent workspace.
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

# Agent CLIs — Claude Code, OpenAI Codex.
# Installed at build time (as root) as the baked-in fallback version.
# setup-agents.sh updates both at runtime into a separate vscode-owned npm
# prefix (~/.npm-global) instead — `--security-opt no-new-privileges`
# (devcontainer.json) disables sudo at runtime, and npm can't rewrite symlinks
# in root-owned /usr/bin without it even if the files themselves are chowned.
RUN npm install -g \
        @anthropic-ai/claude-code \
        @openai/codex \
    && npm cache clean --force

# Pre-create mount targets for the persisted config named volumes, owned by
# vscode. Docker seeds a named volume from the image path's content (incl.
# ownership) on first mount — without this the dir comes up root-owned and
# sudo can't fix it later, because runArgs sets --security-opt
# no-new-privileges, which disables sudo entirely.
RUN mkdir -p /home/vscode/.claude /home/vscode/.codex \
        /home/vscode/.config/gh /home/vscode/.config/github-app /home/vscode/.history \
    && chown -R vscode:vscode /home/vscode/.claude /home/vscode/.codex \
        /home/vscode/.config /home/vscode/.history
