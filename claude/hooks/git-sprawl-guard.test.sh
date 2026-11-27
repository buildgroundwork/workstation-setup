#!/usr/bin/env bash
# Tests for git-sprawl-guard.sh, the PreToolUse hook that keeps a project's
# worktrees under its own .claude/worktrees/ and caps both the linked
# worktrees and the unmerged local branches that have no open PR.
#
# Each case builds a throwaway repo (with a bare origin, so origin/main
# exists), feeds the hook a Bash tool payload on stdin as Claude Code does,
# and reads its verdict: "deny" when it prints a deny decision, "allow" when
# it prints nothing. No `set -e`: a failing hook must surface as a FAIL line
# from assert_eq.
#
# A stub `gh` stands in for GitHub: `gh pr list` prints the head branches
# listed in $STUB_PRS (none by default), exits 1 when $STUB_FAIL is set, and
# logs each call to $STUB_LOG.
#
# Run: claude/hooks/git-sprawl-guard.test.sh

set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/git-sprawl-guard.sh"
PASS=0
FAIL=0

SCRATCH=$(mktemp -d)
trap 'rm -rf "$SCRATCH"' EXIT

# The hook and these tests run git with no user or system config, so a
# machine's own settings (hooks, aliases, identity) can't change a verdict.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com
export GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

mkdir -p "$SCRATCH/bin"
cat >"$SCRATCH/bin/gh" <<'EOF'
#!/bin/bash
echo "$*" >>"$STUB_LOG"
[[ -n "${STUB_FAIL:-}" ]] && exit 1
[[ -f "$STUB_PRS" ]] && cat "$STUB_PRS"
exit 0
EOF
chmod +x "$SCRATCH/bin/gh"
export PATH="$SCRATCH/bin:$PATH" STUB_PRS="$SCRATCH/prs" STUB_LOG="$SCRATCH/gh.log"
: >"$STUB_LOG"

# new_repo <name> -> the path of a repo on main, pushed to its own bare origin.
new_repo() {
  local dir="$SCRATCH/$1"
  mkdir -p "$dir"
  git init -q --bare -b main "$dir.git"
  git init -q -b main "$dir"
  git -C "$dir" commit -q --allow-empty -m init
  git -C "$dir" remote add origin "$dir.git"
  git -C "$dir" push -q origin main
  (cd "$dir" && pwd -P)
}

# verdict <cwd> <command> -> "deny" or "allow" for that Bash command.
verdict() {
  local out
  out=$(jq -n --arg d "$1" --arg c "$2" '{tool_name: "Bash", cwd: $d, tool_input: {command: $c}}' | "$HOOK")
  if [[ "$(jq -r '.hookSpecificOutput.permissionDecision // empty' <<<"$out" 2>/dev/null)" == deny ]]; then
    echo deny
  else
    echo allow
  fi
}

# reason <cwd> <command> -> the deny reason, empty when allowed.
reason() {
  jq -n --arg d "$1" --arg c "$2" '{tool_name: "Bash", cwd: $d, tool_input: {command: $c}}' \
    | "$HOOK" | jq -r '.hookSpecificOutput.permissionDecisionReason // empty'
}

assert_eq() {
  local got="$1" want="$2" label="$3"
  if [[ "$got" == "$want" ]]; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label (got [$got], want [$want])"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local text="$1" want="$2" label="$3"
  if [[ "$text" == *"$want"* ]]; then
    echo "PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $label (no [$want] in [$text])"
    FAIL=$((FAIL + 1))
  fi
}

# ── worktrees belong under the project's .claude/worktrees ───────────────────
repo=$(new_repo wt)
assert_eq "$(verdict "$repo" 'git worktree add .claude/worktrees/a')" allow \
  "a worktree under .claude/worktrees is allowed"
assert_eq "$(verdict "$repo" 'git worktree add -b feature .claude/worktrees/b')" allow \
  "a new-branch worktree under .claude/worktrees is allowed"
assert_eq "$(verdict "$repo" 'git worktree add --detach .claude/worktrees/c HEAD')" allow \
  "a detached worktree under .claude/worktrees is allowed"
assert_eq "$(verdict "$repo" "git worktree add $repo/.claude/worktrees/d")" allow \
  "an absolute path under .claude/worktrees is allowed"
assert_eq "$(verdict "$repo" 'git worktree add ../elsewhere')" deny \
  "a sibling directory is denied"
assert_eq "$(verdict "$repo" 'git worktree add /private/tmp/scratch-wt origin/main')" deny \
  "a path under /private/tmp is denied"
assert_eq "$(verdict "$repo" 'git worktree add .claude/worktrees/../../x')" deny \
  "a path that climbs out of .claude/worktrees is denied"
assert_eq "$(verdict "$repo" 'git worktree add -f --detach /tmp/x HEAD')" deny \
  "flags before a path outside the project don't hide it"
assert_eq "$(verdict "$repo" 'true && git worktree add ../elsewhere')" deny \
  "a worktree add after && is checked"
assert_contains "$(reason "$repo" 'git worktree add ../elsewhere')" "$repo/.claude/worktrees/" \
  "the deny reason names the project's worktrees directory"

# ── only `worktree add` is checked, and only as a command ────────────────────
assert_eq "$(verdict "$repo" 'git worktree list')" allow "worktree list is allowed"
assert_eq "$(verdict "$repo" 'git worktree prune')" allow "worktree prune is allowed"
assert_eq "$(verdict "$repo" 'git worktree remove ../elsewhere')" allow "worktree remove is allowed"
assert_eq "$(verdict "$repo" 'echo "git worktree add ../elsewhere"')" allow \
  "the words inside a string are allowed"
assert_eq "$(verdict "$repo" 'git status')" allow "an unrelated git command is allowed"
assert_eq "$(verdict "$repo" 'ls -la')" allow "a non-git command is allowed"

# ── where the repo comes from ────────────────────────────────────────────────
assert_eq "$(verdict "$SCRATCH" 'git worktree add ../elsewhere')" allow \
  "outside a repo the hook has nothing to judge"
assert_eq "$(verdict "$SCRATCH" "git -C $repo worktree add ../elsewhere")" deny \
  "git -C names the repo when cwd is elsewhere"
assert_eq "$(verdict "$repo/.claude" 'git worktree add worktrees/e')" allow \
  "a relative path resolves from the cwd, not the repo root"

# ── a linked worktree counts the main one's directory, not its own ───────────
git -C "$repo" worktree add -q .claude/worktrees/a
assert_eq "$(verdict "$repo/.claude/worktrees/a" 'git worktree add ../b')" allow \
  "from a linked worktree, a sibling under the main .claude/worktrees is allowed"
assert_eq "$(verdict "$repo/.claude/worktrees/a" 'git worktree add .claude/worktrees/b')" deny \
  "from a linked worktree, a path under its own .claude/worktrees is denied"

# ── the worktree cap ─────────────────────────────────────────────────────────
repo=$(new_repo cap)
git -C "$repo" config workstation.maxWorktrees 2
git -C "$repo" worktree add -q .claude/worktrees/one
assert_eq "$(verdict "$repo" 'git worktree add .claude/worktrees/two')" allow \
  "one linked worktree under a cap of two allows a second"
git -C "$repo" worktree add -q .claude/worktrees/two
assert_eq "$(verdict "$repo" 'git worktree add .claude/worktrees/three')" deny \
  "two linked worktrees at a cap of two deny a third"
assert_contains "$(reason "$repo" 'git worktree add .claude/worktrees/three')" "worktrees/one" \
  "the cap's deny reason lists the existing worktrees"
assert_contains "$(reason "$repo" 'git worktree add .claude/worktrees/three')" "checkout --detach" \
  "the cap's deny reason says to reuse one by checking out the commit"
rm -rf "$repo/.claude/worktrees/two"
assert_eq "$(verdict "$repo" 'git worktree add .claude/worktrees/three')" allow \
  "a worktree whose directory is gone no longer counts"

repo=$(new_repo default)
for n in 1 2 3 4; do git -C "$repo" worktree add -q ".claude/worktrees/w$n"; done
assert_eq "$(verdict "$repo" 'git worktree add .claude/worktrees/w5')" deny \
  "the default cap is four linked worktrees"

# ── unmerged local branches ──────────────────────────────────────────────────
repo=$(new_repo br)
git -C "$repo" config workstation.maxBranches 2
assert_eq "$(verdict "$repo" 'git checkout -b first')" allow \
  "no unmerged branches under a cap of two allows a new one"
git -C "$repo" checkout -q -b one
git -C "$repo" commit -q --allow-empty -m one
git -C "$repo" checkout -q main
git -C "$repo" checkout -q -b two
git -C "$repo" commit -q --allow-empty -m two
git -C "$repo" checkout -q main
assert_eq "$(verdict "$repo" 'git checkout -b three')" deny "checkout -b at the cap is denied"
assert_eq "$(verdict "$repo" 'git checkout -B three')" deny "checkout -B at the cap is denied"
assert_eq "$(verdict "$repo" 'git switch -c three')" deny "switch -c at the cap is denied"
assert_eq "$(verdict "$repo" 'git switch --create three')" deny "switch --create at the cap is denied"
assert_eq "$(verdict "$repo" 'git branch three')" deny "git branch <name> at the cap is denied"
assert_eq "$(verdict "$repo" 'git branch three origin/main')" deny "git branch <name> <start> at the cap is denied"
assert_eq "$(verdict "$repo" 'git worktree add -b three .claude/worktrees/t')" deny \
  "worktree add -b at the cap is denied"
assert_contains "$(reason "$repo" 'git checkout -b three')" "one" \
  "the branch deny reason lists the unmerged branches"
assert_contains "$(reason "$repo" 'git checkout -b three')" "workstation.maxBranches" \
  "the branch deny reason names the setting"
assert_eq "$(verdict "$repo" 'git checkout main')" allow "switching to an existing branch is allowed"
assert_eq "$(verdict "$repo" 'git checkout one')" allow "checking out an existing branch is allowed"
assert_eq "$(verdict "$repo" 'git branch')" allow "listing branches is allowed"
assert_eq "$(verdict "$repo" 'git branch --list')" allow "git branch --list is allowed"
assert_eq "$(verdict "$repo" 'git branch -d one')" allow "deleting a branch is allowed"
assert_eq "$(verdict "$repo" 'git branch -D two')" allow "force-deleting a branch is allowed"
assert_eq "$(verdict "$repo" 'git worktree add .claude/worktrees/plain')" allow \
  "a worktree on an existing or detached ref makes no branch"
assert_eq "$(verdict "$repo" 'git checkout -- file.txt')" allow "checking out a file is allowed"
assert_eq "$(verdict "$repo" 'git commit -m "git checkout -b x"')" allow \
  "the words inside a commit message are allowed"

git -C "$repo" merge -q --no-edit one
git -C "$repo" push -q origin main
assert_eq "$(verdict "$repo" 'git checkout -b three')" allow \
  "a branch merged into origin/main no longer counts"

repo=$(new_repo brdefault)
for n in 1 2 3 4 5; do
  git -C "$repo" checkout -q -b "b$n" main
  git -C "$repo" commit -q --allow-empty -m "b$n"
done
git -C "$repo" checkout -q main
assert_eq "$(verdict "$repo" 'git checkout -b b7')" allow "five unmerged branches are under the default cap"
git -C "$repo" checkout -q -b b6 main
git -C "$repo" commit -q --allow-empty -m b6
git -C "$repo" checkout -q main
assert_eq "$(verdict "$repo" 'git checkout -b b7')" deny "the default cap is six unmerged branches"
git -C "$repo" config workstation.maxWorktrees 1
assert_eq "$(verdict "$repo" 'git checkout -b b7')" deny "the worktree cap does not change the branch cap"

# ── a branch with an open PR does not count ──────────────────────────────────
repo=$(new_repo brpr)
git -C "$repo" config workstation.maxBranches 2
for n in one two three four; do
  git -C "$repo" checkout -q -b "$n" main
  git -C "$repo" commit -q --allow-empty -m "$n"
done
git -C "$repo" checkout -q main
printf 'one\ntwo\nthree\n' >"$STUB_PRS"
assert_eq "$(verdict "$repo" 'git checkout -b five')" allow \
  "four unmerged branches, three with open PRs, leave one counted under a cap of two"
printf 'one\ntwo\n' >"$STUB_PRS"
assert_eq "$(verdict "$repo" 'git checkout -b five')" deny \
  "two counted branches reach a cap of two once only two have PRs"
reply=$(reason "$repo" 'git checkout -b five')
assert_contains "$reply" "three (" "a branch without a PR is listed"
assert_contains "$reply" "open PR doesn't count" "the deny reason says PR branches are exempt"
assert_eq "$([[ "$reply" == *"  one ("* ]] && echo listed || echo unlisted)" unlisted \
  "a branch with an open PR is not listed"
printf 'one\ntwo\nthree\nfour\n' >"$STUB_PRS"
assert_eq "$(verdict "$repo" 'git worktree add -b five .claude/worktrees/five')" allow \
  "with every branch under review, a new branch is allowed"
: >"$STUB_PRS"

# ── GitHub is asked only once the cap is reached ─────────────────────────────
repo=$(new_repo brlazy)
git -C "$repo" config workstation.maxBranches 2
git -C "$repo" checkout -q -b one main
git -C "$repo" commit -q --allow-empty -m one
git -C "$repo" checkout -q main
: >"$STUB_LOG"
assert_eq "$(verdict "$repo" 'git checkout -b two')" allow "one unmerged branch under a cap of two is allowed"
assert_eq "$(wc -c <"$STUB_LOG" | tr -d ' ')" 0 "gh is not called below the cap"
git -C "$repo" checkout -q -b two main
git -C "$repo" commit -q --allow-empty -m two
git -C "$repo" checkout -q main
verdict "$repo" 'git checkout -b three' >/dev/null
assert_contains "$(cat "$STUB_LOG")" "pr list" "gh pr list is called once the cap is reached"

# ── when GitHub can't answer, the command is allowed ─────────────────────────
assert_eq "$(STUB_FAIL=1 verdict "$repo" 'git checkout -b three')" allow \
  "a failing gh allows branch creation at the cap"
assert_eq "$(verdict "$repo" 'git checkout -b three')" deny "the same command is denied once gh answers"

# ── the deny lists branches oldest first and marks the stale ones ────────────
repo=$(new_repo brage)
git -C "$repo" config workstation.maxBranches 2
git -C "$repo" checkout -q -b recent-work main
git -C "$repo" commit -q --allow-empty -m recent
git -C "$repo" checkout -q -b ancient-work main
GIT_COMMITTER_DATE="2026-01-01T00:00:00Z" git -C "$repo" commit -q --allow-empty -m ancient
git -C "$repo" checkout -q main
reply=$(reason "$repo" 'git checkout -b new')
assert_contains "$reply" "ancient-work (" "the older branch is listed with its age"
assert_contains "$reply" ", stale)" "a branch past the stale age is marked stale"
assert_contains "$reply" "recent-work (0d)" "a fresh branch is listed with no stale mark"
assert_eq "$([[ "${reply%%recent-work (*}" == *"ancient-work ("* ]] && echo first || echo last)" first \
  "the oldest branch comes first"
git -C "$repo" config workstation.staleBranchDays 100000
assert_eq "$([[ "$(reason "$repo" 'git checkout -b new')" == *", stale)"* ]] && echo marked || echo unmarked)" unmarked \
  "workstation.staleBranchDays sets how old counts as stale"

echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
