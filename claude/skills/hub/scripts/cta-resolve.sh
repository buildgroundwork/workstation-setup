#!/bin/bash
# cta-resolve.sh — run a claude-tmux-attention tmux script (status | popup) from
# whatever version is CURRENTLY installed, resolved from the plugin manifest.
#
# Why this exists: tmux.conf needs a stable, version-free path to the plugin's
# status-line + popup scripts. The plugin cache is version-stamped
# (.../claude-tmux-attention/<version>/...) and there is no stable "current"
# symlink the updater maintains — so a hardcoded version path in tmux.conf goes
# stale on every plugin bump (and silently strands the status bar on an old
# renderer). This reads the ONE authoritative value the updater DOES keep
# current — `installPath` in installed_plugins.json — and execs the requested
# script under it. No globbing, no version math, no scraping: a single known-good
# field, read defensively.
#
# Usage (from tmux.conf):
#   status-right "#(~/.claude/skills/hub/scripts/cta-resolve.sh status) ..."
#   bind-key -T claude A run-shell "~/.claude/skills/hub/scripts/cta-resolve.sh popup"
#
# Contract: on ANY failure (manifest missing, jq absent, field gone, script not
# found) it exits 0 with no output. A status-line command must never emit junk,
# and a missing popup should no-op rather than error — same discipline the
# plugin's own scripts follow.

set -euo pipefail

what="${1:-}"
case "$what" in
  status) script="tmux/status.sh" ;;
  popup)  script="tmux/popup.sh" ;;
  *) exit 0 ;;   # unknown request: silently do nothing
esac

MANIFEST="$HOME/.claude/plugins/installed_plugins.json"
PLUGIN_KEY="claude-tmux-attention@gusto-claude-code"

command -v jq >/dev/null 2>&1 || exit 0
[[ -r "$MANIFEST" ]] || exit 0

# installPath is the updater-maintained current-version dir for the plugin.
root=$(jq -r --arg k "$PLUGIN_KEY" \
  '.plugins[$k][0].installPath // empty' "$MANIFEST" 2>/dev/null) || exit 0
[[ -n "$root" && -x "$root/$script" ]] || exit 0

exec "$root/$script"
