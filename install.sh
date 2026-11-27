#!/bin/bash
# One-line installer: downloads the latest NotchAI release and opens it.
set -euo pipefail

main() {
  local url="${NOTCHAI_URL:-https://github.com/AadithKK/NotchAI/releases/latest/download/NotchAI.zip}"
  local dest="${NOTCHAI_DIR:-$HOME/Applications}"

  [[ "$(uname -s)" == "Darwin" ]] || { echo "NotchAI only runs on a Mac."; exit 1; }
  [[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 15 ]] || { echo "NotchAI needs macOS 15 or newer. Update in System Settings, then try again."; exit 1; }

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  echo "Downloading NotchAI..."
  curl -fL --progress-bar "$url" -o "$tmp/NotchAI.zip"
  ditto -x -k "$tmp/NotchAI.zip" "$tmp/unpacked"
  # Check the download is intact before touching an existing install.
  codesign --verify --strict "$tmp/unpacked/NotchAI.app" || { echo "The download looks damaged. Please try again."; exit 1; }

  if [[ -z "${NOTCHAI_DIR:-}" ]]; then pkill -x NotchAI 2>/dev/null || true; fi
  mkdir -p "$dest"
  rm -rf "$dest/NotchAI.app"
  ditto "$tmp/unpacked/NotchAI.app" "$dest/NotchAI.app"
  if [[ -z "${NOTCHAI_DIR:-}" ]]; then open "$dest/NotchAI.app"; fi
  echo "Done! NotchAI is in $dest. Click its menu-bar icon, then Settings > AI Providers to add your key."
}

# Wrapped in a function so a half-downloaded script never runs.
main "$@"
