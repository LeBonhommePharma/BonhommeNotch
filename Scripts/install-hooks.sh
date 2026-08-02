#!/usr/bin/env bash
# Install BonhommeNotch managed hook bridges into user agent config dirs.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS="$ROOT/hooks"

install_claude() {
  local dest="$HOME/.claude/bonhomme-notch"
  mkdir -p "$dest"
  cp "$HOOKS/notch-hook.py" "$dest/notch-hook.py"
  chmod +x "$dest/notch-hook.py"
  echo "Installed Claude bridge → $dest/notch-hook.py"
  echo "Wire into ~/.claude/settings.json hooks (see README)."
}

install_cursor() {
  local dest="$HOME/.cursor"
  mkdir -p "$dest"
  cp "$HOOKS/notch-cursor-hook.py" "$dest/bonhomme-notch-cursor-hook.py"
  chmod +x "$dest/bonhomme-notch-cursor-hook.py"
  echo "Installed Cursor bridge → $dest/bonhomme-notch-cursor-hook.py"
}

install_codex() {
  local dest="$HOME/.codex"
  mkdir -p "$dest"
  cp "$HOOKS/notch-codex-hook.py" "$dest/bonhomme-notch-codex-hook.py"
  chmod +x "$dest/bonhomme-notch-codex-hook.py"
  echo "Installed Codex bridge → $dest/bonhomme-notch-codex-hook.py"
}

install_claude
install_cursor
install_codex
echo "Done. Socket default: ~/Library/Application Support/BonhommeNotch/notch.sock"
