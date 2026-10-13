# 🖥️ Workstation Setup
Set up a developer Mac workstation

## Instructions

### Install Homebrew
```sh
$ /usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
```

### Authenticate with GitHub
```
$ ssh-keygen
$ pbcopy < ~/.ssh/id_rsa.pub
```
**Add this public key to the GitHub account for the machine.**

### Run this script
```sh
$ git clone git@github.com:buildgroundwork/workstation-setup.git ~/.workstation
$ cd ~/.workstation
$ ./setup.sh
```

### Set up logrotation
- Copy the example configuration from the logrotate.d directory
- Modify for each project you would like logs rotated for

### Set up tmuxinator
- Copy the example configuration from the tmuxinator directory
- Modify for each project
- Add a `tmuxinator start <project>` line for each project to `tmuxinator/mux`
- Run `mux` to start every session and attach

The `workstation` session is always started. Each project's `claude` window
reports its status through the istatus skill (`Ctrl-b A A` for the popup,
`Ctrl-b A S` for the floating status pane; see `tmux.conf`). This needs tmux
3.8 or later.

### Set up authorized keys
- Add keys for machines you would like SSH access into to the `authorized_keys` file.

## What's included?
### Via homebrew
- pure-prompt
  Command line prettification for zsh.
- Inconsolata-g font
  Developer-centric fixed-width font.
- MacVim
- iTerm2
- PostgreSQL
- ripgrep
  Fast text search replacement for ack and ag.
- mise
  Ruby and Node version management.
- yarn
- git
- wget
- jq
  Command-line JSON processor and pretty-printer.
- gh
- flock, coreutils
  Used by the Claude session tooling and `mux`.
- fzf
  Fast fuzzy find for the command line and vim.
- git-author
- git-together

### Via mise
- ruby 3.4
- node (LTS)
- bundler (gem install)
- claude-powerline (npm install)

### Claude Code
- `claude/CLAUDE.md`, `claude/settings.json`, `claude/skills` and
  `claude/hooks` are linked into `~/.claude`
- the inter-session plugin, used by the hub and istatus skills

### Directly downloaded
- oh-my-zsh
- zsh-syntax-highlighting
- vim config

### Config files
- .zshrc
- .gemrc
- .vimrc.local
- .gitconfig
- .git-together
- .git-author-template

## Notes

To update iTerm preferences:
```sh
$ defaults export -app iTerm - > iterm/profile.plist
```

To update CCMenu preferences:
```sh
$ defaults export -app CCMenu - > ccmenu.plist
```

## M1 architecture notes

The `git-together` formula has not been updated for the M1 chip, and will not install properly.  To run `git author` on an M1 machine, remove (or comment out) `git-together` from the Brewfile and build/install `git-together` from [source](https://github.com/kejadlen/git-together).
