#!/usr/bin/env bash
# Tests for the main path's argument parsing: what lands in tasks and what after -- reaches the
# agent. herd runs for real against a fake herdr on PATH that logs every call.
#
#   bash tests/args.sh        (make test runs it)
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
herd=$here/../bin/herd
export HERD_BACKEND=tui   # the fake herdr below, also when run in the Herdr app

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; [[ -z ${2:-} ]] || sed 's/^/       /' <<<"$2"; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name" "$(cat "$T/out" "$T/calls" 2>/dev/null)"; fi; }

# A repo with a Tasks.herd, and a herdr that records its args and answers like the real one.
setup() {
  T=$(mktemp -d)
  export HOME=$T GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  repo=$T/proj
  git init -q -b main "$repo" && git -C "$repo" commit -q --allow-empty -m init
  printf 'feat/a: do a\n' >"$repo/Tasks.herd"
  printf 'feat/b: do b\n' >"$T/other.herd"
  mkdir "$T/bin"
  cat >"$T/bin/herdr" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$T/calls"
case "\$1 \$2" in
  "worktree create") echo '{"result":{"root_pane":{"pane_id":"w9:p1"}}}' ;;
esac
EOF
  chmod +x "$T/bin/herdr"
}
run_herd() { (cd "$repo" && PATH=$T/bin:$PATH "$herd" -r "$repo" -b main -p w9 "$@") >"$T/out" 2>&1; rc=$?; }
started() { local want="agent start $1 --kind claude --pane w9:p1 --timeout 90000 --"; shift
  [[ $# -eq 0 ]] || want+=" $*"; grep -qxF -- "$want" "$T/calls"; }
created_only() { [[ $(grep -c '^worktree create' "$T/calls") == 1 ]] && grep -q "^worktree create .*--branch $1 " "$T/calls"; }

echo "herd -f file -- <agent args>"
setup; run_herd -f "$T/other.herd" -- --permission-mode auto
check "exits 0" test "$rc" = 0
check "only the file's task gets a worktree" created_only feat/b
check "agent gets the args after --" started feat-b --permission-mode auto

echo "herd -- <agent args> (default Tasks.herd)"
setup; run_herd -- --model sonnet
check "exits 0" test "$rc" = 0
check "only Tasks.herd's task gets a worktree" created_only feat/a
check "agent gets the args after --" started feat-a --model sonnet

echo "herd branch prompt -- <agent args>"
setup; run_herd feat/c "do c" -- --model opus
check "exits 0" test "$rc" = 0
check "only the named task gets a worktree" created_only feat/c
check "agent gets the args after --" started feat-c --model opus

echo "herd branch prompt (no --)"
setup; run_herd feat/c "do c"
check "exits 0" test "$rc" = 0
check "agent gets no extra args" started feat-c

echo
echo "$pass passed, $fail failed"
((fail == 0))
