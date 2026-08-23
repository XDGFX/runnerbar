#!/bin/bash
# One-command install: SwiftBar via Homebrew if missing, plugin wired in,
# SwiftBar launched and set to start at login.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if ! command -v brew >/dev/null; then
    echo "Homebrew is required (https://brew.sh) — install it and re-run." >&2
    exit 1
fi

if ! brew list --cask swiftbar >/dev/null 2>&1 && [ ! -d /Applications/SwiftBar.app ]; then
    echo "Installing SwiftBar…"
    brew install --cask swiftbar
fi

# If SwiftBar already has a plugin folder, copy the plugin into it — a copy,
# not a symlink, because SwiftBar's folder-watcher is unreliable with
# symlinks. Otherwise point SwiftBar at this clone, so future `git pull`s
# update the plugin in place.
existing=$(defaults read com.ameba.SwiftBar PluginDirectory 2>/dev/null || true)
if [ -n "$existing" ] && [ "$existing" != "$SCRIPT_DIR" ]; then
    cp "$SCRIPT_DIR/runnerbar.30s.sh" "$existing/"
    chmod +x "$existing/runnerbar.30s.sh"
    echo "Plugin copied into $existing (re-run this script after a git pull to update)."
else
    defaults write com.ameba.SwiftBar PluginDirectory "$SCRIPT_DIR"
    echo "SwiftBar plugin folder set to $SCRIPT_DIR."
fi

# Start at login, added only once.
if ! osascript -e 'tell application "System Events" to get the name of every login item' 2>/dev/null | grep -q SwiftBar; then
    osascript -e 'tell application "System Events" to make login item at end with properties {path:"/Applications/SwiftBar.app", hidden:true}' >/dev/null
fi

open -a SwiftBar
echo "Done — look for the runner glyph in your menu bar."
