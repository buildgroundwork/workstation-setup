#!/bin/bash
# Install pianobar wrapper and config.
#
# Called by ~/.workstation/setup.sh. Expects $HOMEBREW_DIR to be set
# by the caller; falls back to /opt/homebrew if not.
#
# See ./README.md for what each file does and how config assembly works.

set -e

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
: "${HOMEBREW_DIR:=/opt/homebrew}"

mkdir -p ~/.config/pianobar

chmod +x "$DIR/eventcmd" "$DIR/toggle" "$DIR/pianobar-loop" "$DIR/pianobar-respawn"

ln -sf "$DIR/eventcmd"         ~/.config/pianobar/eventcmd
ln -sf "$DIR/toggle"           ~/.config/pianobar/toggle
ln -sf "$DIR/pianobar-loop"    "$HOMEBREW_DIR/bin/pianobar-loop"
ln -sf "$DIR/pianobar-respawn" "$HOMEBREW_DIR/bin/pianobar-respawn"

if [[ ! -f "$DIR/config.local" ]]; then
    cp "$DIR/config.local.example" "$DIR/config.local"
    echo "WARN: created $DIR/config.local from example —" >&2
    echo "      edit it with your Pandora email and keychain account, then re-run setup.sh" >&2
    echo "      pianobar will not work until config.local is filled in" >&2
    exit 0
fi

sed "s|%HOME%|$HOME|g" "$DIR/config.shared" > ~/.config/pianobar/config
cat "$DIR/config.local" >> ~/.config/pianobar/config
