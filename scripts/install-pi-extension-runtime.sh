#!/usr/bin/env bash
set -euo pipefail

# Install the Pi extension's build where Pi can load it without dev dependencies.
#
# Loaded from pi-extension/ itself, the extension's imports of
# @earendil-works/pi-coding-agent, pi-tui and typebox find the devDependencies
# copies before the host's, so every Pi session loads a second Pi stack. This
# packs the build and installs it with production dependencies only, so those
# imports reach the host's copies as Pi intends.
#
# Each install is a new release folder behind a `current` symlink: Node loads a
# module by its real path, so a running session keeps the release it loaded
# (its later lazy imports still find their files) while new sessions take the
# new one.
#
# Usage:
#   scripts/install-pi-extension-runtime.sh [--build] [--dest <dir>] [--keep <n>]
#
# Options:
#   --build         Run tsc first, so dist/ matches src/
#   --dest <dir>    Install root (default: ~/.local/share/remote-pi)
#   --keep <n>      Release folders to keep, the current one included (default: 3)
#   --help, -h      Show this help
#
# Then point Pi at <dest>/current/node_modules/remote-pi in settings.json and
# /reload the running sessions.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXT_DIR="$(cd "$SCRIPT_DIR/../pi-extension" && pwd)"

DO_BUILD=false
DEST_DIR="$HOME/.local/share/remote-pi"
KEEP=3

while [[ $# -gt 0 ]]; do
  case "$1" in
    --build) DO_BUILD=true; shift ;;
    --dest) DEST_DIR="$2"; shift 2 ;;
    --keep) KEEP="$2"; shift 2 ;;
    --help|-h) sed -n '3,27p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ ! "$KEEP" =~ ^[1-9][0-9]*$ ]]; then
  echo "--keep needs a positive whole number, got: $KEEP" >&2
  exit 2
fi

if $DO_BUILD; then
  (cd "$EXT_DIR" && ./node_modules/.bin/tsc -p .)
fi
if [[ ! -f "$EXT_DIR/dist/index.js" ]]; then
  echo "No build in $EXT_DIR/dist. Run with --build." >&2
  exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# --ignore-scripts: the production dependencies ship prebuilt; nothing needs to run.
(cd "$EXT_DIR" && npm pack --ignore-scripts --loglevel=error --pack-destination "$WORK" >/dev/null)
TARBALL="$(ls "$WORK"/remote-pi-*.tgz)"

RELEASES="$DEST_DIR/releases"
mkdir -p "$RELEASES"
RELEASE="$(mktemp -d "$RELEASES/$(date +%Y%m%dT%H%M%S)-XXXX")"
echo '{"private": true}' > "$RELEASE/package.json"
# --omit=peer with --legacy-peer-deps keeps npm from installing the host packages as peers.
(cd "$RELEASE" && npm install --omit=dev --omit=peer --legacy-peer-deps --ignore-scripts \
  --no-audit --no-fund --loglevel=error "$TARBALL" >/dev/null)

for host_pkg in @earendil-works/pi-coding-agent @earendil-works/pi-tui @earendil-works/pi-ai @earendil-works/pi-agent-core typebox; do
  if [[ -e "$RELEASE/node_modules/$host_pkg" ]]; then
    echo "Release still contains host package $host_pkg; not switching." >&2
    exit 1
  fi
done

ln -sfn "releases/$(basename "$RELEASE")" "$DEST_DIR/current.new"
mv -Tf "$DEST_DIR/current.new" "$DEST_DIR/current"

# Oldest first; release names sort by time.
mapfile -t ALL < <(find "$RELEASES" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
for ((i = 0; i < ${#ALL[@]} - KEEP; i++)); do
  rm -rf "${RELEASES:?}/${ALL[$i]}"
done

echo "Installed $(basename "$RELEASE") at $DEST_DIR/current"
echo "Pi path: $DEST_DIR/current/node_modules/remote-pi"
