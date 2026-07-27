#!/usr/bin/env bash
# Prints the image version identifier baked in at build time. Installed into
# the image as /usr/local/bin/agent-devcontainer-version (see Dockerfile).
# Maps a running project container back to its source image/build — the
# `version:` line is the Git commit SHA, identical to the published
# `ghcr.io/sadotu/agent-devcontainer:<sha>` image tag.
set -euo pipefail
exec cat /opt/agent-devcontainer/VERSION
