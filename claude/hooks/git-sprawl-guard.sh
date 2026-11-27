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
#     already has `workstation.maxBranches` local branches (default 6) that
#     are neither merged into origin/main nor the head of an open pull request.
#     This cap is separate from the worktree cap: a pair works in one worktree
#     but can have several branches in flight, switching between them there. Merged branches and open-PR branches don't count:
#     work waiting on review must not stop an agent starting the next piece.
#     The deny message lists the counted branches oldest first, with the days
#     since each one's last commit, and marks those older than
#     `workstation.staleBranchDays` (default 14) as stale, since the staler a
#     branch, the less likely it holds anything worth keeping.
#
# The open PRs come from `gh pr list`, asked only once the unmerged branches
# reach the cap, so an ordinary branch creation costs nothing extra. When gh
# can't answer (not installed, offline, not signed in, or no reply in five
# seconds), the hook allows the command rather than block work on a flaky
# network.
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
default_stale_branch_days=14

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

# run_with_timeout <seconds> <command...> -- the command's output and status,
# or a kill after the time is up. The watcher's output goes to /dev/null so it
# doesn't hold open a pipe the caller is reading.
run_with_timeout() {
  local seconds="$1" pid watcher status
  shift
  "$@" &
  pid=$!
  (sleep "$seconds"; kill "$pid" 2>/dev/null) >/dev/null 2>&1 &
  watcher=$!
  wait "$pid"
  status=$?
  kill "$watcher" 2>/dev/null
  return "$status"
}

# open_pr_branches <dir> -> the head branch of each open pull request, one per
# line. Fails when GitHub can't be asked: no gh, no network, no sign-in, or no
# answer in five seconds.
open_pr_branches() {
  command -v gh >/dev/null 2>&1 || return 1
  (cd "$1" && GH_PROMPT_DISABLED=1 run_with_timeout 5 \
    gh pr list --state open --limit 200 --json headRefName --jq '.[].headRefName' 2>/dev/null)
}

# check_branch_creation <dir>
check_branch_creation() {
  local dir="$1" ref="" candidate line tip name branches="" prs counted="" count=0
  local max stale_days now age flag
  for candidate in origin/main origin/master main master; do
    if git -C "$dir" rev-parse --verify -q "refs/remotes/$candidate" >/dev/null 2>&1 \
      || git -C "$dir" rev-parse --verify -q "refs/heads/$candidate" >/dev/null 2>&1; then
      ref="$candidate"
      break
    fi
  done
  [[ -n "$ref" ]] || return 0

  # One "<last commit epoch> <name>" line per unmerged branch.
  while IFS= read -r line; do
    [[ -n "$line" ]] && branches+="${line}${nl}"
  done < <(git -C "$dir" for-each-ref --no-merged "$ref" --format='%(committerdate:unix) %(refname:short)' refs/heads 2>/dev/null)

  max=$(config_number "$dir" workstation.maxBranches "$default_max_branches")
  (( $(count_lines "$branches") >= max )) || return 0

  prs=$(open_pr_branches "$dir") || return 0

  stale_days=$(config_number "$dir" workstation.staleBranchDays "$default_stale_branch_days")
  now=$(date +%s)
  while IFS=' ' read -r tip name; do
    [[ -n "$name" ]] || continue
    [[ "${nl}${prs}${nl}" == *"${nl}${name}${nl}"* ]] && continue
    age=$(( (now - tip) / 86400 ))
    flag=""
    (( age >= stale_days )) && flag=", stale"
    counted+="  ${name} (${age}d${flag})${nl}"
    count=$((count + 1))
  done < <(printf '%s' "$branches" | sort -n)

  if (( count >= max )); then
    deny "This repo already has ${count} local branches with no open PR that aren't merged into ${ref} (the cap is ${max}, set with git config workstation.maxBranches; a branch with an open PR doesn't count). Don't create another. Oldest first, with the days since each one's last commit; a stale one (${stale_days}+ days) is unlikely to hold work worth keeping:${nl}${counted}Delete a branch that is merged or superseded (check its tip is on main, and record the tip so it can be restored), or push one worth keeping and open a PR for it, or reuse an existing branch for this work. If the cap is too low for this project, tell the user rather than raising it yourself."
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
