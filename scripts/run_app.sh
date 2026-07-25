#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

swift build
APP_DIR="$(bash scripts/make_app_bundle.sh debug)"
osascript -e 'tell application "Evo Control" to quit' >/dev/null 2>&1 || true
open "$APP_DIR"
