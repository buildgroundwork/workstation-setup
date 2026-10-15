#!/bin/bash

if [[ `uname -m` == 'arm64' ]]; then
  HOMEBREW_DIR="/opt/homebrew"
else
  HOMEBREW_DIR="/usr/local"
fi

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd "$DIR"

set -ex

# Homebrew packages
brew bundle
brew services restart postgresql@17
brew services restart redis
brew services restart logrotate

# Install oh my zsh
if [ ! -d ~/.oh-my-zsh ]; then
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
fi

if [ ! -d ~/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting ]; then
    git clone https://github.com/zsh-users/zsh-syntax-highlighting.git ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-syntax-highlighting
fi

# scripts
ln -sf $DIR/update.sh $HOMEBREW_DIR/bin/workstation-update
ln -sf $DIR/tmuxinator/mux $HOMEBREW_DIR/bin/mux

# ruby and node, via mise. default-gems is read by mise's ruby installs.
ln -sf $DIR/default-gems ~/.default-gems
mise use --global ruby@3.4 node@lts
eval "$(mise activate bash --shims)"
gem install bundler

# Claude Code status line (installed rather than run through npx, which
# starts a fresh node process on every status line render)
npm install --global @owloops/claude-powerline

# vim
if [ ! -d ~/.vim ]; then
    git clone https://github.com/buildgroundwork/vim-config.git ~/.vim
    pushd ~/.vim
    ./install
    popd
fi

pushd ~/.vim
git pull
git submodule update --init
popd

# rails
if [ ! -d ~/.rails ]; then
    git clone https://github.com/buildgroundwork/rails-config.git ~/.rails

else
  pushd ~/.rails
    git checkout master
    git fetch
    git merge --ff-only origin/master
  popd
fi

# tmux
export TMUX_PLUGIN_MANAGER_PATH=~/.tmux/plugins/
ln -sf $DIR/tmux.conf ~/.tmux.conf
if [ ! -d ~/.tmux/plugins/tpm ]; then
  git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
fi
~/.tmux/plugins/tpm/bin/install_plugins
~/.tmux/plugins/tpm/bin/update_plugins all

# create directories
mkdir -p ~/workspace

# preserve git author
GIT_USER_EMAIL=$(git config --get --global user.email)
GIT_USER_NAME=$(git config --get --global user.name)

# dotfiles
ln -sf $DIR/zshrc ~/.zshrc
ln -sf $DIR/gemrc ~/.gemrc
rm -f ~/.gitconfig
cp -f $DIR/gitconfig ~/.gitconfig
ln -sf $DIR/.git-together ~/.git-together
ln -sf $DIR/.gitignore_global ~/.gitignore_global
ln -sf $DIR/vimrc.local ~/.vimrc.local
mkdir -p ~/.claude
ln -sf $DIR/claude/CLAUDE.md ~/.claude/CLAUDE.md
# Personal skills are repo-managed; -n replaces the existing symlink on
# re-runs instead of nesting a link inside it.
ln -sfn $DIR/claude/skills ~/.claude/skills
# Personal hooks (e.g. the sed/cat/head/tail-viewer block), same pattern as skills.
ln -sfn $DIR/claude/hooks ~/.claude/hooks
# settings.json is shared config; the secret-bearing env stays in the
# untracked settings.local.json alongside it.
ln -sf $DIR/claude/settings.json ~/.claude/settings.json
# Commands the skills tell every session to run (istatus decide, isend, ...)
mkdir -p ~/.local/bin
for f in $DIR/claude/skills/istatus/scripts/istatus.sh $DIR/claude/skills/hub/scripts/{isend,iflag,ilist}.sh; do
  ln -sf "$f" ~/.local/bin/$(basename "$f" .sh)
done
ln -sf ~/.rails/railsrc ~/.railsrc
mkdir -p ~/.config/bat
ln -sf $DIR/batconfig ~/.config/bat/config
ln -sf $DIR/authorized_keys ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
ln -sf $DIR/tmuxinator ~/.config

# iTerm2 preferences
for f in $DIR/iterm/*.sh; do
  [ -x "$f" ] && "$f"
done

# git-together
touch ~/.git-author-template
git config --global commit.template ~/.git-author-template

# restore git author
git config --global user.name "$GIT_USER_NAME"
git config --global user.email $GIT_USER_EMAIL

# GitHub credentials (the copied gitconfig has no credential helper)
gh auth status &>/dev/null && gh auth setup-git

# Claude Code plugins that the tmux setup depends on (istatus and hub use
# the inter-session message bus)
claude plugin marketplace add https://github.com/yilunzhang/claude-code-inter-session.git
claude plugin install inter-session@inter-session
claude plugin update inter-session@inter-session
INTER_SESSION_DIR=$(jq -r '.plugins["inter-session@inter-session"][0].installPath' ~/.claude/plugins/installed_plugins.json)
# Its scripts re-exec into this venv for their Python deps. Rebuild it when its
# interpreter no longer runs, e.g. after a Homebrew Python upgrade. macOS's own
# python3 is too old for the plugin, so build it from Homebrew's.
INTER_SESSION_VENV=~/.claude/data/inter-session/venv
"$INTER_SESSION_VENV/bin/python" -c '' 2>/dev/null || rm -rf "$INTER_SESSION_VENV"
[ -d "$INTER_SESSION_VENV" ] || $HOMEBREW_DIR/bin/python3 -m venv "$INTER_SESSION_VENV"
"$INTER_SESSION_VENV/bin/pip" install --quiet --upgrade -r "$INTER_SESSION_DIR/skills/inter-session/requirements.txt"
# Start the bus client in every session, not only after /inter-session runs.
# This edits the installed copy, so it has to be redone after every update.
"$INTER_SESSION_VENV/bin/python" "$INTER_SESSION_DIR/skills/inter-session/bin/auto_start.py" --on
# Its options live in claude/settings.json under pluginConfigs.

# ccmenu
# defaults import net.sourceforge.cruisecontrol.CCMenu ccmenu.plist

# logrotate
ln -sf $DIR/logrotate.d/*.conf $HOMEBREW_DIR/etc/logrotate.d/
