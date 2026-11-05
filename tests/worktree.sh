#!/usr/bin/env bash
# Tests for create_agent meeting a worktree already at its path (left by a start that didn't
# finish): reused when there is nothing to lose, otherwise named and left alone. herdr is faked.
#
#   bash tests/worktree.sh        (make test runs it)
# shellcheck disable=SC2034  # the globals set here are herd's, read by the functions sourced below
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$here/../bin/herd"
set +e

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; [[ -z ${2:-} ]] || sed 's/^/       /' <<<"$2"; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name" "$(cat "$T/out" "$T/calls" 2>/dev/null)"; fi; }

AGENT_CWD=""   # cwd of a running agent, if any
h() {
  echo "$*" >>"$T/calls"
  case "$1 $2" in
    "agent list") jq -n --arg c "$AGENT_CWD" '{result: {agents: (if $c == "" then [] else [{cwd: $c}] end)}}' ;;
    "worktree open" | "worktree create") echo '{"result":{"root_pane":{"pane_id":"w9:p1"}}}' ;;
    "agent start") ;;
    *) echo "unexpected h $*" >&2; return 1 ;;
  esac
}

# A repo whose leftover worktree for feat/x sits where create_agent puts it.
setup() {
  T=$(mktemp -d)
  export HOME=$T GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  repo=$T/proj base=main machine="" parent_ws="" kind=claude agent_args=() AGENT_CWD=""
  git init -q -b main "$repo" && git -C "$repo" commit -q --allow-empty -m init
  left=$T/git/wt/proj/feat-x
  git -C "$repo" worktree add -q -b feat/x "$left" main
}
run_create() { (set -e; create_agent feat/x) >"$T/out" 2>&1; rc=$?; }
opened() { grep -q '^worktree open .*--path '"$left" "$T/calls"; }
created() { grep -q '^worktree create' "$T/calls"; }
still_there() { [[ -d $left ]] && git -C "$repo" worktree list | grep -q "$left"; }
refused() { [[ $rc -ne 0 ]] && grep -q "$1" "$T/out" && grep -q "herd rm feat/x" "$T/out" && ! opened && ! created && still_there; }

echo "leftover worktree"
setup; run_create
check "clean, on its branch, nothing beyond base, no agent: reused" eval 'test $rc -eq 0 && opened && ! created'

setup; touch "$left/new.txt"; run_create
check "uncommitted changes: refused, named, kept" refused "uncommitted changes"

setup; git -C "$left" commit -q --allow-empty -m work; run_create
check "commits beyond base: refused, named, kept" refused "commits not in main"

setup; git -C "$left" switch -q -c other; run_create
check "another branch: refused, named, kept" refused "on other, not feat/x"

setup; AGENT_CWD=$left; run_create
check "an agent running in it: refused, named, kept" refused "agent is already running"

setup; rm -rf "$left"; mkdir -p "$left"; run_create
check "a plain directory, not a worktree: refused, named, kept" \
  eval 'test $rc -ne 0 && grep -q "not a worktree of" "$T/out" && ! opened && ! created && test -d "$left"'

echo "no leftover"
setup; git -C "$repo" worktree remove "$left"; git -C "$repo" branch -qD feat/x; run_create
check "creates the worktree as before" eval 'test $rc -eq 0 && created && ! opened'

echo "$pass passed, $fail failed"
((fail == 0))
