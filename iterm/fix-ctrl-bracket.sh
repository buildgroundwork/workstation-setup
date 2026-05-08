#!/bin/bash
# Ensure Ctrl-[ sends Escape (0x1b) in iTerm2.
#
# iTerm updates and crashes can reset this mapping, causing Ctrl-[ to stop
# working as Escape in tmux session picker and vim-mode CLIs.

PLIST="$HOME/Library/Preferences/com.googlecode.iterm2.plist"
PB=/usr/libexec/PlistBuddy
KEY="0x5b-0x40000"

i=0
while $PB -c "Print ':New Bookmarks:$i:Name'" "$PLIST" &>/dev/null; do
  $PB -c "Delete ':New Bookmarks:$i:Keyboard Map:$KEY'" "$PLIST" 2>/dev/null
  $PB -c "Add ':New Bookmarks:$i:Keyboard Map:$KEY' dict" "$PLIST"
  $PB -c "Add ':New Bookmarks:$i:Keyboard Map:$KEY:Action' integer 11" "$PLIST"
  $PB -c "Add ':New Bookmarks:$i:Keyboard Map:$KEY:Text' string '0x1b'" "$PLIST"
  i=$((i+1))
done
