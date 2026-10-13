#!/bin/bash
# Ensure Ctrl-[ sends Escape (0x1b) in iTerm2.
#
# iTerm updates and crashes can reset this mapping, causing Ctrl-[ to stop
# working as Escape in tmux session picker and vim-mode CLIs.
#
# IMPORTANT: every reference to $KEY uses ${KEY} (braces). Bare $KEY:Action
# would work under bash but breaks under zsh, where ${KEY:A} is the
# absolute-path modifier (silently swallowing :A and ":T" into the parameter
# expansion). See git history for the bug this caused.

PLIST="$HOME/Library/Preferences/com.googlecode.iterm2.plist"
PB=/usr/libexec/PlistBuddy
KEY="0x5b-0x40000"

i=0
while $PB -c "Print ':New Bookmarks:$i:Name'" "$PLIST" &>/dev/null; do
  $PB -c "Delete ':New Bookmarks:$i:Keyboard Map:${KEY}'" "$PLIST" 2>/dev/null
  $PB -c "Add ':New Bookmarks:$i:Keyboard Map:${KEY}' dict" "$PLIST"
  $PB -c "Add ':New Bookmarks:$i:Keyboard Map:${KEY}:Action' integer 11" "$PLIST"
  $PB -c "Add ':New Bookmarks:$i:Keyboard Map:${KEY}:Text' string '0x1b'" "$PLIST"
  i=$((i+1))
done

# Verify both keys made it in. If only Text or only Action ended up present,
# something is wrong (probably another shell-expansion gotcha) and we want
# loud, not silent.
i=0
while $PB -c "Print ':New Bookmarks:$i:Name'" "$PLIST" &>/dev/null; do
  have_action=$($PB -c "Print ':New Bookmarks:$i:Keyboard Map:${KEY}:Action'" "$PLIST" 2>/dev/null)
  have_text=$($PB -c "Print ':New Bookmarks:$i:Keyboard Map:${KEY}:Text'" "$PLIST" 2>/dev/null)
  if [ "$have_action" != "11" ] || [ "$have_text" != "0x1b" ]; then
    echo "ERROR: profile $i missing Ctrl-[ binding (Action=$have_action Text=$have_text)" >&2
    exit 1
  fi
  i=$((i+1))
done
echo "ok: Ctrl-[ → 0x1b verified across $i profile(s)"
