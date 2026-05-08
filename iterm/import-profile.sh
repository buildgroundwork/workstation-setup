#!/bin/bash
# Import iTerm2 profile preferences from the workstation plist
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
defaults import -app iTerm "$DIR/profile.plist"
