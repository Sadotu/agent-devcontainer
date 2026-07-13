#!/usr/bin/env bash
# Instantiate this template into a new project directory.
#
# Usage:
#   ./scaffold.sh <project-name> <target-dir> [gh-owner] [app-id]
#
# Example:
#   ./scaffold.sh notify-bot ../notify-bot Sadotu 4217970
#
# Copies every file except this script, secrets/, and .git/, substituting:
#   __PROJECT_NAME__ -> <project-name>
#   __GH_OWNER__     -> [gh-owner]   (default: Sadotu)
#   __APP_ID__       -> [app-id]     (default: 4217970 — the shared
#                                      container-coding-agent GitHub App;
#                                      pass a different one if this project
#                                      uses its own App)
set -euo pipefail

PROJECT_NAME="${1:?usage: scaffold.sh <project-name> <target-dir> [gh-owner] [app-id]}"
TARGET_DIR="${2:?usage: scaffold.sh <project-name> <target-dir> [gh-owner] [app-id]}"
GH_OWNER="${3:-Sadotu}"
APP_ID="${4:-4217970}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -e "$TARGET_DIR" ] && [ -n "$(ls -A "$TARGET_DIR" 2>/dev/null)" ]; then
  echo "ERROR: $TARGET_DIR exists and is not empty." >&2
  exit 1
fi

mkdir -p "$TARGET_DIR"
rsync -a --exclude='.git' --exclude='scaffold.sh' --exclude='secrets' \
  "$SCRIPT_DIR/" "$TARGET_DIR/"

FILES=$(grep -rl "__PROJECT_NAME__\|__GH_OWNER__\|__APP_ID__" "$TARGET_DIR" 2>/dev/null || true)
for f in $FILES; do
  sed -i \
    -e "s/__PROJECT_NAME__/$PROJECT_NAME/g" \
    -e "s/__GH_OWNER__/$GH_OWNER/g" \
    -e "s/__APP_ID__/$APP_ID/g" \
    "$f"
done

chmod +x "$TARGET_DIR/.devcontainer/dc" \
  "$TARGET_DIR/.devcontainer/setup-agents.sh" \
  "$TARGET_DIR/.devcontainer/gh-app-token.sh" \
  "$TARGET_DIR/.devcontainer/git-credential-github-app.sh" \
  "$TARGET_DIR/.devcontainer/githooks/pre-push"

echo "Scaffolded '$PROJECT_NAME' into $TARGET_DIR"
echo ""
echo "Remaining steps:"
echo "1. cd $TARGET_DIR && git init && git config init.defaultBranch main"
echo "2. mkdir secrets && cp /path/to/private-key.pem secrets/  (gitignored — for the manual container setup step)"
echo "3. Review README.md's app-description placeholder and the App scopes if using a different GitHub App."
echo "4. git remote add origin git@github.com:$GH_OWNER/$PROJECT_NAME.git"
echo "5. git add -A && git commit -m '...' && git push -u origin main"
