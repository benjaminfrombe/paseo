#!/usr/bin/env bash
# Fast local Paseo desktop build + install.
# Usage: scripts/build-paseo.sh [--deps] [--install] [--full] [--dmg]
#   --deps     force build:app-deps (auto-detected otherwise)
#   --install  install to /Applications via llmgate after build
#   --full     always run npm ci + app-deps (ignore cache)
#   --dmg      also build DMG/ZIP distribution artifacts (default: .app only)
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$PWD/node_modules/.bin:$PATH"

CACHE_DIR=".paseo-build-cache"
mkdir -p "$CACHE_DIR"
LOCK_HASH_FILE="$CACHE_DIR/lockfile.sha256"
DEPS_HASH_FILE="$CACHE_DIR/app-deps.sha256"
RELEASE_APP="packages/desktop/release/mac-arm64/Paseo.app"

force_deps=0
force_full=0
do_install=0
do_dmg=0
for arg in "$@"; do
  case "$arg" in
    --deps) force_deps=1 ;;
    --full) force_full=1 ;;
    --install) do_install=1 ;;
    --dmg) do_dmg=1 ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

lock_hash=$(shasum -a 256 package-lock.json | awk '{print $1}')
deps_hash=$(cat \
  packages/server/package.json \
  packages/client/package.json \
  packages/plugin/package.json 2>/dev/null | shasum -a 256 | awk '{print $1}')

prev_lock=""; [ -f "$LOCK_HASH_FILE" ] && prev_lock=$(cat "$LOCK_HASH_FILE")
prev_deps=""; [ -f "$DEPS_HASH_FILE" ] && prev_deps=$(cat "$DEPS_HASH_FILE")

if [ "$force_full" = 1 ] || [ "$lock_hash" != "$prev_lock" ]; then
  if [ "$force_full" = 1 ]; then
    echo "==> npm ci (--full)"
  else
    echo "==> package-lock.json changed since last build -> npm ci"
  fi
  npm ci
  echo "$lock_hash" > "$LOCK_HASH_FILE"
else
  echo "==> lockfile unchanged, skipping npm ci"
fi

if [ "$force_deps" = 1 ] || [ "$force_full" = 1 ] || [ "$deps_hash" != "$prev_deps" ]; then
  echo "==> build:app-deps"
  npm run build:app-deps
  echo "$deps_hash" > "$DEPS_HASH_FILE"
else
  echo "==> app-deps unchanged, skipping build:app-deps"
fi

echo "==> server + frontend build (parallel)"
npm run build:server &
server_pid=$!
( npm run build --workspace=@getpaseo/expo-two-way-audio && \
  cd packages/app && cross-env PASEO_WEB_PLATFORM=electron npx expo export --platform web ) &
frontend_pid=$!
fail=0
wait "$server_pid" || fail=1
wait "$frontend_pid" || fail=1
[ "$fail" = 0 ] || { echo "build failed" >&2; exit 1; }

echo "==> electron-builder (.app only; use --dmg for DMG/ZIP)"
if [ "$do_dmg" = 1 ]; then
  npm run build:fast --workspace=@getpaseo/desktop --
else
  npm run build:fast --workspace=@getpaseo/desktop -- --dir
fi

echo "==> codesign check"
if codesign --verify --deep "$RELEASE_APP" 2>/dev/null; then
  echo "==> signature valid, skipping ad-hoc re-sign"
else
  echo "==> signature invalid -> ad-hoc re-sign"
  codesign --force --deep --sign - "$RELEASE_APP"
fi

if [ "$do_install" = 1 ]; then
  echo "==> quitting Paseo and installing"
  osascript -e 'quit app "Paseo"' || true
  sleep 2
  sudo -n /usr/local/bin/llmgate install-app "$PWD/$RELEASE_APP"
fi

echo "==> done: $RELEASE_APP"
