#!/usr/bin/env bash
set -euo pipefail

CONFIGURATION="${1:-debug}"
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT_DIR/.build/Evo Control.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

if [[ "$CONFIGURATION" == "release" ]]; then
  EXECUTABLE="$ROOT_DIR/.build/release/EvoControl"
else
  EXECUTABLE="$ROOT_DIR/.build/debug/EvoControl"
fi

if [[ ! -x "$EXECUTABLE" ]]; then
  echo "Executable not found: $EXECUTABLE" >&2
  exit 1
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR"
cp "$EXECUTABLE" "$MACOS_DIR/EvoControl"
cp "$ROOT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
chmod +x "$MACOS_DIR/EvoControl"

echo "$APP_DIR"
