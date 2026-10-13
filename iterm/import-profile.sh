#!/bin/bash
# Import iTerm2 profile preferences from the workstation plist
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
defaults import com.googlecode.iterm2 "$DIR/profile.plist"
