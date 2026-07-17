#!/usr/bin/env bash
# Project scaffolder — baked into the shared image at /usr/local/bin/init.
#
# Solves the chicken-and-egg: `dc` and `devcontainer.json` must exist in a
# project *before* any container can be created, so they can't be produced by
# the devcontainer lifecycle (postCreate runs too late — the files it would
# write are the ones needed to start it). This runs via a plain `docker run`
# instead, which needs no project files:
#
#   cd /path/to/your-project
#   docker run --rm -it -v "$PWD":/out ghcr.io/sadotu/agent-devcontainer init
#
# It writes .devcontainer/dc (verbatim from the baked template — single source
# of truth, no more hand-copying) and .devcontainer/devcontainer.json (template
# + your answers) into the mounted project. Command is identical for every
# project; project-specific values come from prompts (pre-filled from the
# mounted repo's git remote when present), not from the command line.
set -euo pipefail

OUT=/out
TEMPLATES=/opt/agent-devcontainer/templates

if [ ! -d "$OUT" ]; then
  echo "ERROR: nothing mounted at /out." >&2
  echo "Run with your project bind-mounted:" >&2
  echo '  docker run --rm -it -v "$PWD":/out ghcr.io/sadotu/agent-devcontainer init' >&2
  exit 1
fi

# --- Auto-detect owner/name from the mounted repo's git remote ----------------
# Turns the prompts into confirmations when the project is already a clone.
# `-c safe.directory=*`: we run as root against a bind mount owned by the host
# user, which git otherwise rejects as "dubious ownership".
detect_owner="" detect_name=""
if remote_url="$(git -C "$OUT" -c safe.directory='*' remote get-url origin 2>/dev/null)"; then
  # Normalise git@host:owner/name.git and https://host/owner/name(.git) to owner/name.
  slug="$(printf '%s' "$remote_url" \
    | sed -E -e 's#\.git$##' -e 's#^git@[^:]+:##' -e 's#^[a-z]+://[^/]+/##')"
  if printf '%s' "$slug" | grep -q '/'; then
    detect_owner="${slug%%/*}"
    detect_name="${slug##*/}"
  fi
fi

default_name="${detect_name:-}"
default_owner="${detect_owner:-Sadotu}"
default_appid="4217970"

ask() { # prompt-label  default  -> echoes chosen value
  local label="$1" def="$2" ans
  while :; do
    if ! read -rp "$label${def:+ [$def]}: " ans; then
      # EOF (closed stdin / non-interactive): take the default if there is
      # one, otherwise there's no way to proceed — fail loudly instead of
      # looping forever.
      [ -n "$def" ] && { printf '%s' "$def"; return 0; }
      echo "ERROR: no input for '$label' and no default — run with 'docker run -it'." >&2
      exit 1
    fi
    [ -z "$ans" ] && ans="$def"
    [ -n "$ans" ] && { printf '%s' "$ans"; return 0; }
    echo "  (required)" >&2
  done
}

echo "=== agent-devcontainer project init ==="
if [ -n "$detect_owner$detect_name" ]; then
  echo "Detected git remote: ${detect_owner:-?}/${detect_name:-?} — press enter to accept."
fi
PROJECT_NAME="$(ask 'Project name' "$default_name")"
GH_OWNER="$(ask 'GitHub owner' "$default_owner")"
APP_ID="$(ask 'GitHub App ID' "$default_appid")"

DEST="$OUT/.devcontainer"
mkdir -p "$DEST"

# Overwrite guard — never clobber an existing file without an explicit yes.
confirm_overwrite() { # path -> 0 write, 1 skip
  local path="$1" ans
  [ -e "$path" ] || return 0
  read -rp "$(basename "$path") already exists. Overwrite? [y/N]: " ans || ans=""
  case "$ans" in [yY]*) return 0 ;; *) echo "  skipped $(basename "$path")"; return 1 ;; esac
}

if confirm_overwrite "$DEST/dc"; then
  install -m 0755 "$TEMPLATES/dc" "$DEST/dc"
  echo "  wrote .devcontainer/dc"
fi

if confirm_overwrite "$DEST/devcontainer.json"; then
  sed -e "s|__PROJECT_NAME__|$PROJECT_NAME|g" \
      -e "s|__GH_OWNER__|$GH_OWNER|g" \
      -e "s|__APP_ID__|$APP_ID|g" \
      "$TEMPLATES/devcontainer.json.template" > "$DEST/devcontainer.json"
  echo "  wrote .devcontainer/devcontainer.json"
fi

# Files were written as root (docker run default user). Hand them back to
# whoever owns the mounted project dir so they're not root-locked on native
# Linux hosts. No-op on Docker Desktop / WSL bind mounts (ownership is faked).
owner_uid_gid="$(stat -c '%u:%g' "$OUT" 2>/dev/null || echo '')"
if [ -n "$owner_uid_gid" ] && [ "$owner_uid_gid" != "0:0" ]; then
  chown -R "$owner_uid_gid" "$DEST" 2>/dev/null || true
fi

cat <<EOF

Done. Wrote .devcontainer/dc and .devcontainer/devcontainer.json.

Next, from this directory (on the host):
  1. Have one Bitwarden vault item with custom TEXT fields 'app-id' (the
     GitHub App ID) and 'private-key-b64' (base64 -w0 private-key.pem).
     First start finds it by those fields — no item ID needed — and asks
     for your Bitwarden login. See the agent-devcontainer README,
     "Repository access".
  2. ./.devcontainer/dc up      (then: ./.devcontainer/dc shell)

If 'dc up' fails with 'ENOENT ... uv_cwd': this docker run staled your
shell's working directory — cd out and back into the project, retry.
If the Bitwarden step fails during 'up': fix and re-run with
'./.devcontainer/dc setup' (no rebuild needed).
EOF
