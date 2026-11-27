#!/bin/bash
# PreToolUse hook: keep a project's git worktrees and branches from piling up.
# Stale worktrees (each with its own node_modules or build output) make an
# endpoint scanner churn through the file system, and a pile of unmerged
# branches hides which work is live. A rule in CLAUDE.md ("remove a worktree
# you made once it's no longer needed") wasn't enough on its own, so this hook
# denies the command that creates the pile:
#
#   - `git worktree add <path>` must name a direct child of the project's own
#     <main worktree>/.claude/worktrees/, so a project stays self-contained and
#     one path can be excluded from scanning. Not a sibling directory, a
#     scratchpad, or /tmp.
#   - It is denied once the repo already has `workstation.maxWorktrees` linked
#     worktrees (default 4: one per pair, up to three pairs, plus the anchor).
#   - A command that creates a branch (`git checkout -b`, `git switch -c`,
#     `git branch <name>`, `git worktree add -b`) is denied once the repo
#     already has `workstation.maxBranches` local branches not merged into
#     origin/main (default 6). Merged branches don't count.
#
# Both limits are per-repo `git config` values, so a project with more pairs
# raises its own cap. The deny message says what to do instead: reuse a
# worktree by checking out the commit in it (`git checkout --detach <sha>`),
# or remove or merge what's finished.
#
# A worktree whose directory is gone (`prunable` in `git worktree list`) is not
# counted. The harness's own EnterWorktree tool doesn't go through Bash and
# already creates under .claude/worktrees/, so it is unaffected.
#
# Matches `git` as an actual command word (start of the line, or after ;, &&,
# ||, & or a newline), with optional `-C <path>` and `-c <k=v>` before the
# subcommand, so a string literal that merely mentions the command is allowed.
# Known gaps, on purpose: a line of a heredoc body that starts with the command
# is read as a command, and a command run inside `bash -c "..."` isn't seen.
# Both fail one way each (a wrong deny with a message that says how to proceed,
# or a miss), and parsing shell fully isn't worth it for a guard.
#
# Runs under macOS's bash 3.2: no mapfile, no associative arrays.
#
# Tests: claude/hooks/git-sprawl-guard.test.sh

payload=$(cat)
command=$(jq -r '.tool_input.command // ""' <<<"$payload")
cwd=$(jq -r '.cwd // ""' <<<"$payload")

[[ "$command" == *git* ]] || exit 0

default_max_worktrees=4
default_max_branches=6

nl=$'\n'
command_start="(^|[;&${nl}]|\|\|)[[:space:]]*"
git_prefix="${command_start}git([[:space:]]+(-C[[:space:]]+[^[:space:]]+|-c[[:space:]]+[^[:space:]]+|--no-pager))*[[:space:]]+"
worktree_add="${git_prefix}worktree[[:space:]]+add([^;&|${nl}]*)"
checkout_new_branch="${git_prefix}(checkout|switch)[[:space:]]+([^;&|${nl}]*[[:space:]])?(-b|-B|-c|-C|--create|--force-create)([[:space:]]|\$)"
branch_new="${git_prefix}branch[[:space:]]+[^-;&|[:space:]]"
chdir_option="-C[[:space:]]+[\"']?([^\"'[:space:]]+)"

deny() {
  jq -n --arg reason "$1" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $reason
    }
  }'
  exit 0
}

# repo_dir <text before the subcommand> -> the physical directory the git
# command runs in: its `-C <path>` (relative to the cwd), else the cwd.
repo_dir() {
  local dir="$cwd"
  if [[ "$1" =~ $chdir_option ]]; then
    dir="${BASH_REMATCH[1]}"
    [[ "$dir" == /* ]] || dir="$cwd/$dir"
  fi
  (cd "$dir" 2>/dev/null && pwd -P)
}

# physical_path <path> -> the path with its existing part resolved (symlinks,
# `..`), and any part that doesn't exist yet appended as written.
physical_path() {
  local p="$1" rest=""
  while [[ ! -d "$p" && "$p" != "/" && "$p" != "." ]]; do
    rest="/$(basename "$p")$rest"
    p=$(dirname "$p")
  done
  printf '%s%s\n' "$(cd "$p" 2>/dev/null && pwd -P)" "$rest"
}

# load_worktrees <dir> -> sets main_worktree and linked_worktrees (a newline
# separated list of the linked worktrees whose directories still exist).
load_worktrees() {
  local line path="" prunable=0 seen_main=0
  main_worktree=""
  linked_worktrees=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      "worktree "*) path="${line#worktree }"; prunable=0 ;;
      prunable*) prunable=1 ;;
      "")
        if [[ -n "$path" ]]; then
          if (( ! seen_main )); then
            main_worktree="$path"
            seen_main=1
          elif (( ! prunable )); then
            linked_worktrees+="${path}${nl}"
          fi
        fi
        path=""
        ;;
    esac
  done < <(git -C "$1" worktree list --porcelain 2>/dev/null; echo)
}

config_number() {
  local value
  value=$(git -C "$1" config --get "$2" 2>/dev/null)
  [[ "$value" =~ ^[0-9]+$ ]] && echo "$value" || echo "$3"
}

# count_lines <text> -> the number of non-empty lines.
count_lines() {
  local n=0 line
  while IFS= read -r line; do
    [[ -n "$line" ]] && n=$((n + 1))
  done <<<"$1"
  echo "$n"
}

# check_worktree_add <dir> <arguments after `worktree add`>
check_worktree_add() {
  local dir="$1" token path="" skip=0 target want name
  local -a tokens
  read -ra tokens <<<"$2"
  for token in "${tokens[@]}"; do
    if (( skip )); then skip=0; continue; fi
    case "$token" in
      -b|-B) creates_branch=1; skip=1 ;;
      --reason) skip=1 ;;
      -*) ;;
      *) path="${token//[\"\']/}"; break ;;
    esac
  done
  [[ -n "$path" ]] || return 0

  load_worktrees "$dir"
  [[ -n "$main_worktree" ]] || return 0

  [[ "$path" == "~/"* ]] && path="$HOME/${path#\~/}"
  [[ "$path" == /* ]] || path="$dir/$path"
  target=$(physical_path "$path")
  want="$main_worktree/.claude/worktrees/"
  name="${target#"$want"}"
  if [[ "$target" != "$want"* || -z "$name" || "$name" == */* || "$name" == .. ]]; then
    deny "Create worktrees as direct children of the project's own ${want}, not at ${target}. Keeping them inside the project keeps it self-contained and lets one path be excluded from file-system scanning. For example: git worktree add ${want}<name> <ref>. To check a commit, don't add a worktree for it: reuse one you already have and run git checkout --detach <sha> in it."
  fi

  local max linked
  max=$(config_number "$dir" workstation.maxWorktrees "$default_max_worktrees")
  linked=$(count_lines "$linked_worktrees")
  if (( linked >= max )); then
    deny "This repo already has ${linked} linked worktrees (the cap is ${max}: one per pair plus one for the anchor, set with git config workstation.maxWorktrees). Don't add another. Existing worktrees:${nl}${linked_worktrees}Reuse one: in it, run git checkout --detach <sha> to check a commit, or switch its branch. Or remove one you no longer need, after git status --ignored shows nothing worth keeping, with git worktree remove <path>. If the cap is too low for this project, tell the user rather than raising it yourself."
  fi
}

# check_branch_creation <dir>
check_branch_creation() {
  local dir="$1" ref="" candidate branch unmerged="" count max
  for candidate in origin/main origin/master main master; do
    if git -C "$dir" rev-parse --verify -q "refs/remotes/$candidate" >/dev/null 2>&1 \
      || git -C "$dir" rev-parse --verify -q "refs/heads/$candidate" >/dev/null 2>&1; then
      ref="$candidate"
      break
    fi
  done
  [[ -n "$ref" ]] || return 0

  while IFS= read -r branch; do
    [[ -n "$branch" ]] && unmerged+="  ${branch}${nl}"
  done < <(git -C "$dir" for-each-ref --no-merged "$ref" --format='%(refname:short)' refs/heads 2>/dev/null)

  max=$(config_number "$dir" workstation.maxBranches "$default_max_branches")
  count=$(count_lines "$unmerged")
  if (( count >= max )); then
    deny "This repo already has ${count} local branches not merged into ${ref} (the cap is ${max}, set with git config workstation.maxBranches). Don't create another. Unmerged branches:${nl}${unmerged}Finish one first: merge it, or delete it if it is merged or superseded (check its tip is on main, and record the tip so it can be restored). Or reuse an existing branch for this work. If the cap is too low for this project, tell the user rather than raising it yourself."
  fi
}

creates_branch=0

if [[ "$command" =~ $worktree_add ]]; then
  match="${BASH_REMATCH[0]}"
  arguments="${BASH_REMATCH[${#BASH_REMATCH[@]} - 1]}"
  dir=$(repo_dir "${match%%worktree*}")
  if [[ -n "$dir" ]]; then
    check_worktree_add "$dir" "$arguments"
    (( creates_branch )) && check_branch_creation "$dir"
  fi
fi

if [[ "$command" =~ $checkout_new_branch ]]; then
  match="${BASH_REMATCH[0]}"
  prefix="${match%%checkout*}"
  [[ "$prefix" == "$match" ]] && prefix="${match%%switch*}"
  dir=$(repo_dir "$prefix")
  [[ -n "$dir" ]] && check_branch_creation "$dir"
fi

if [[ "$command" =~ $branch_new ]]; then
  match="${BASH_REMATCH[0]}"
  dir=$(repo_dir "${match%%branch*}")
  [[ -n "$dir" ]] && check_branch_creation "$dir"
fi

exit 0
