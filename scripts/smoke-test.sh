#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLED_APP="$HOME/Applications/NotchAI.app"
if [[ -d "${NOTCHAI_APP_PATH:-}" ]]; then
  APP="$NOTCHAI_APP_PATH"
elif [[ -d "$INSTALLED_APP" ]]; then
  APP="$INSTALLED_APP"
else
  APP="$ROOT/build/NotchAI.app"
fi
PROBE="$ROOT/.build/window-probe"

if [[ ! -d "$APP" ]]; then
  echo "FAIL: $APP not built. Run ./scripts/build-app.sh first."
  exit 1
fi

echo "==> Compiling window probe"
swiftc -O -o "$PROBE" "$ROOT/scripts/window-probe.swift"

echo "==> Stopping any previous NotchAI instance"
pkill -x NotchAI 2>/dev/null || true
sleep 0.8

echo "==> Launching $APP"
open "$APP"
sleep 2.5

PID="$(pgrep -x NotchAI | head -1 || true)"
if [[ -z "${PID}" ]]; then
  echo "FAIL: NotchAI process is not running after launch"
  exit 1
fi
echo "PASS: NotchAI is running (pid ${PID})"

echo "==> Probe on-screen island window"
WINDOWS="$("$PROBE" "$PID")"
echo "$WINDOWS"
COUNT="$(echo "$WINDOWS" | awk -F= '/^count=/{print $2}')"
if [[ "${COUNT:-0}" -lt 1 ]]; then
  echo "FAIL: no on-screen window found for NotchAI"
  exit 1
fi

echo "==> Recent NotchAI unified log"
log show --style compact --last 2m --predicate 'subsystem == "com.aadithkannoth.NotchAI"' 2>/dev/null | tail -12 || true

echo "PASS: launch + island window smoke test"
