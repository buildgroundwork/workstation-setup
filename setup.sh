#!/bin/bash

if [[ `uname -m` == 'arm64' ]]; then
  HOMEBREW_DIR="/opt/homebrew"
else
  HOMEBREW_DIR="/usr/local"
fi

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"
cd $DIR

set -ex

# Homebrew packages
brew bundle
brew services restart postgresql@14
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

# ruby
rbenv install --skip-existing 3.1.3
rbenv install --skip-existing 3.2.0
rbenv global 3.2.0
eval "$(rbenv init -)"
gem install bundler

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

# Netlify
npm list --global netlify-cli
if [ $? -eq 0 ]; then
  npm upgrade --global netlify-cli
else
  npm install --global netlify-cli
fi

# tmux
export TMUX_PLUGIN_MANAGER_PATH=~/.tmux/plugins/
ln -sf $DIR/tmux.conf ~/.tmux.conf
if [ ! -d ~/.tmux/plugins/tpm ]; then
  git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
fi
~/.tmux/plugins/tpm/bin/install_plugins
~/.tmux/plugins/tpm/bin/update_plugins all

# ngrok
mkdir -p ~/.ngrok2
ln -sf $DIR/ngrok/ngrok.yml ~/.ngrok2/ngrok.yml

# create directories
mkdir -p ~/projects

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
ln -sf ~/.rails/railsrc ~/.railsrc
mkdir -p ~/.config/bat
ln -sf $DIR/batconfig ~/.config/bat/config
ln -sf $DIR/authorized_keys ~/.ssh/authorized_keys
chmod 600 ~/.ssh/authorized_keys
ln -sf $DIR/default-gems $(rbenv root)/default-gems
ln -sF $DIR/tmuxinator ~/.config
ln -sf $DIR/mux ~/mux

# iTerm2 profile preferences
defaults import -app iTerm iterm-profile.plist

# git-together
touch ~/.git-author-template
git config --global commit.template ~/.git-author-template

# heroku cli
heroku plugins:install api heroku-builds

# restore git author
git config --global user.name "$GIT_USER_NAME"
git config --global user.email $GIT_USER_EMAIL

# ccmenu
# defaults import net.sourceforge.cruisecontrol.CCMenu ccmenu.plist

# logrotate
ln -sf $DIR/logrotate.d/*.conf $HOMEBREW_DIR/etc/logrotate.d/
