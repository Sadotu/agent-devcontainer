#!/usr/bin/env bash
# Mint a short-lived GitHub App installation access token and print it to stdout.
#
# The only secret this needs is the App's private key. Installation tokens expire
# after ~1 hour, so the result is cached and transparently re-minted when stale.
#
# Credential layout (persisted volume, see devcontainer.json):
#   $GITHUB_APP_DIR/app-id           -> the numeric App ID
#   $GITHUB_APP_DIR/private-key.pem  -> the App's private key (.pem)
#
# Override the target repo with GITHUB_APP_REPO=owner/name.
set -euo pipefail

DEFAULT_APP_DIR="$HOME/.config/github-app"
if [ ! -r "$DEFAULT_APP_DIR/app-id" ] && [ -r /tmp/github-app/app-id ]; then
  DEFAULT_APP_DIR=/tmp/github-app
fi
APP_DIR="${GITHUB_APP_DIR:-$DEFAULT_APP_DIR}"
APP_ID_FILE="$APP_DIR/app-id"
PEM="$APP_DIR/private-key.pem"
CACHE="$APP_DIR/.token-cache"
REPO="${GITHUB_APP_REPO:-${GH_OWNER:?GH_OWNER or GITHUB_APP_REPO must be set}/${PROJECT_NAME:?PROJECT_NAME or GITHUB_APP_REPO must be set}}"

[ -r "$APP_ID_FILE" ] || { echo "gh-app-token: missing $APP_ID_FILE" >&2; exit 1; }
[ -r "$PEM" ]         || { echo "gh-app-token: missing $PEM" >&2; exit 1; }
APP_ID="$(tr -d '[:space:]' < "$APP_ID_FILE")"

now=$(date +%s)

# Reuse a cached token while it still has >5 min of life.
if [ -r "$CACHE" ]; then
  exp="$(sed -n '1p' "$CACHE")"
  tok="$(sed -n '2p' "$CACHE")"
  if [ -n "$exp" ] && [ -n "$tok" ] && [ "$exp" -gt "$((now + 300))" ]; then
    printf '%s\n' "$tok"
    exit 0
  fi
fi

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# Build and RS256-sign a short-lived App JWT (max 10 min; use 9).
iat=$((now - 60))
jexp=$((now + 540))
header="$(printf '%s' '{"alg":"RS256","typ":"JWT"}' | b64url)"
payload="$(printf '{"iat":%s,"exp":%s,"iss":"%s"}' "$iat" "$jexp" "$APP_ID" | b64url)"
signing_input="${header}.${payload}"
sig="$(printf '%s' "$signing_input" | openssl dgst -sha256 -sign "$PEM" | b64url)"
jwt="${signing_input}.${sig}"

api() { curl -sf -H "Authorization: Bearer $jwt" -H "Accept: application/vnd.github+json" "$@"; }

inst_id="$(api "https://api.github.com/repos/$REPO/installation" | jq -r '.id')"
[ -n "$inst_id" ] && [ "$inst_id" != "null" ] || {
  echo "gh-app-token: could not resolve installation id for $REPO (is the App installed on it?)" >&2
  exit 1
}

resp="$(api -X POST "https://api.github.com/app/installations/$inst_id/access_tokens")"
token="$(printf '%s' "$resp" | jq -r '.token')"
expires="$(printf '%s' "$resp" | jq -r '.expires_at')"
[ -n "$token" ] && [ "$token" != "null" ] || {
  echo "gh-app-token: token request failed: $resp" >&2
  exit 1
}

exp_epoch="$(date -d "$expires" +%s 2>/dev/null || echo $((now + 3600)))"
umask 077
printf '%s\n%s\n' "$exp_epoch" "$token" > "$CACHE"
printf '%s\n' "$token"
