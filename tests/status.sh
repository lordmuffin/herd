#!/usr/bin/env bash
# Tests for herd's JSON data layer: `herd status -j` (git facts, agent pane, plan stages),
# `herd status -j -a` (every repo with streams) and `herd show -j`. herdr is faked on PATH the
# way tests/plugin.sh fakes it: it logs every call and answers from JSON files.
#
#   bash tests/status.sh        (make test runs it)
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/.." && pwd)
herd=$root/bin/herd
# Run inside a herdr pane, these would reach the real herdr and its workspaces.
unset HERDR_BIN_PATH HERDR_SOCKET_PATH HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_PANE_ID HERD_RELAY_HOST
export HERD_BACKEND=tui   # the fake herdr below, also when run in the Herdr app

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; [[ -z ${2:-} ]] || sed 's/^/       /' <<<"$2"; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name" "$(cat "$T/out" 2>/dev/null)"; fi; }
called() { grep -qF -- "$1" "$T/calls" 2>/dev/null; }
# jqt <filter>: the filter holds for $T/out.
jqt() { jq -e "$1" "$T/out" >/dev/null 2>&1; }
run() { (cd "$repo" && "$herd" "$@") >"$T/out" 2>"$T/err"; rc=$?; }

# Two repos, proj (streams feat/a, feat/b) and lib (stream fix/c), each a real worktree under
# ~/git/wt/<repo>/, plus a worktree of proj outside ~/git/wt that is not a herd stream. herdr
# answers `worktree list --cwd X` from $T/wt-<repo of X>.json and `agent list` from agents.json.
setup() {
  T=$(mktemp -d)
  export HOME=$T GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  repo=$T/proj lib=$T/lib wt=$T/git/wt/proj/feat-a wtb=$T/git/wt/proj/feat-b wtc=$T/git/wt/lib/fix-c
  for r in "$repo" "$lib"; do git init -q -b main "$r" && git -C "$r" commit -q --allow-empty -m init; done
  git -C "$repo" worktree add -q -b feat/a "$wt"
  git -C "$repo" worktree add -q -b feat/b "$wtb"
  git -C "$repo" worktree add -q -b other "$T/elsewhere"
  git -C "$lib" worktree add -q -b fix/c "$wtc"
  echo one >"$wt/one.txt"; git -C "$wt" add one.txt; git -C "$wt" commit -q -m "add one"
  echo two >"$wt/two.txt"; git -C "$wt" add two.txt; git -C "$wt" commit -q -m "add two: the sequel"
  echo dirt >"$wt/dirt.txt"; echo more >>"$wt/one.txt"
  cat >"$T/wt-proj.json" <<EOF
{"result":{"worktrees":[
  {"path":"$repo","branch":"main","is_linked_worktree":false,"open_workspace_id":"w1"},
  {"path":"$wt","branch":"feat/a","is_linked_worktree":true,"open_workspace_id":"w5"},
  {"path":"$wtb","branch":"feat/b","is_linked_worktree":true,"open_workspace_id":null},
  {"path":"$T/elsewhere","branch":"other","is_linked_worktree":true,"open_workspace_id":null}]}}
EOF
  cat >"$T/wt-lib.json" <<EOF
{"result":{"worktrees":[
  {"path":"$lib","branch":"main","is_linked_worktree":false,"open_workspace_id":null},
  {"path":"$wtc","branch":"fix/c","is_linked_worktree":true,"open_workspace_id":"w7"}]}}
EOF
  agents feat-a w5:p1 "$wt" working feat-b w6:p2 "$wtb/sub" blocked
  mkdir -p "$T/bin"
  cat >"$T/bin/herdr" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$T/calls"
case "\$1 \$2" in
  "worktree list")
    c=\$(git -C "\$4" rev-parse --path-format=absolute --git-common-dir) || exit 1
    cat "$T/wt-\$(basename "\$(dirname "\$c")").json" ;;
  "agent list") cat "$T/agents.json" ;;
  "agent read") printf 'Allow edit of src/x.rs?\n  1. Yes\n  2. No\n' ;;
esac
EOF
  chmod +x "$T/bin/herdr"
  : >"$T/calls"
  export PATH=$T/bin:$ORIG_PATH
}
ORIG_PATH=$PATH

# agents name pane cwd status [...]: what `herdr agent list` returns, with herdr's real field names.
agents() {
  local a=()
  while (($# >= 4)); do
    a+=("$(printf '{"agent":"claude","name":"%s","pane_id":"%s","cwd":"%s","agent_status":"%s","workspace_id":"%s"}' \
      "$1" "$2" "$3" "$4" "${2%%:*}")"); shift 4
  done
  (IFS=,; printf '{"result":{"agents":[%s]}}\n' "${a[*]}") >"$T/agents.json"
}

# plan <worktree> <stage> <status> [title...]: a plan run's state and stages.
plan() {
  local p=$1/.herd/run s=$2 st=$3 i=0 t; shift 3
  mkdir -p "$p"; printf 'stage=%s\nstatus=%s\n' "$s" "$st" >"$p/state"
  : >"$p/stages.md"
  for t in "$@"; do i=$((i + 1)); printf '## Stage %d: %s\nverify: true\n\nDo it.\n\n' "$i" "$t" >>"$p/stages.md"; done
}

# --- herd status -j ----------------------------------------------------------------------------
echo "status -j"
setup; run status -j -b main
check "exits 0" test "$rc" = 0
check "one JSON object per stream, herd's streams only" \
  test "$(jq -r .branch "$T/out" | paste -sd' ' -)" = "feat/a feat/b"
check "keeps the original fields first, in their order, then the new ones" \
  jqt 'select(.branch == "feat/a") | keys_unsorted == ["branch","agent","status","plan","path","workspace",
       "pane_id","host","ahead","dirty","last_commit","plan_detail"]'
check "the original fields are unchanged" \
  jqt "select(.branch == \"feat/a\") | .agent == \"feat-a\" and .status == \"working\" and .plan == \"\"
       and .path == \"$wt\" and .workspace == \"w5\""
check "pane_id comes from herdr's agent list" jqt 'select(.branch == "feat/a") | .pane_id == "w5:p1"'
check "...also for an agent in a directory under the worktree" jqt 'select(.branch == "feat/b") | .pane_id == "w6:p2" and .status == "blocked"'
check "host defaults to hostname -s" jqt ".host == \"$(hostname -s 2>/dev/null || uname -n)\""
check "ahead counts commits ahead of -b" jqt 'select(.branch == "feat/a") | .ahead == 2'
check "dirty counts uncommitted files, untracked included" jqt 'select(.branch == "feat/a") | .dirty == 2'
check "last_commit has sha, subject (colons and all) and rel_time" \
  jqt "select(.branch == \"feat/a\") | .last_commit == {sha: \"$(git -C "$wt" rev-parse --short HEAD)\",
       subject: \"add two: the sequel\", rel_time: .last_commit.rel_time} and (.last_commit.rel_time | test(\"ago\$\"))"
check "a clean stream at the base: ahead 0, dirty 0" jqt 'select(.branch == "feat/b") | .ahead == 0 and .dirty == 0'
check "plan_detail is null with no plan run" jqt 'select(.branch == "feat/a") | .plan_detail == null'

HERD_RELAY_HOST=box run status -j -b main
check "HERD_RELAY_HOST sets host" jqt '.host == "box"'
agents; run status -j -b main
check "no agent: status -, pane_id null" jqt 'select(.branch == "feat/a") | .status == "-" and .pane_id == null'
run status -j -b nosuchref
check "an unknown base gives ahead null, not a failure" bash -c "test $rc = 0 && jq -e 'select(.branch == \"feat/a\") | .ahead == null' '$T/out' >/dev/null"
rm -rf "$wtb"
run status -j -b main
check "a worktree that's gone: git facts null" \
  jqt 'select(.branch == "feat/b") | .ahead == null and .dirty == null and .last_commit == null'
(cd "$repo" && "$herd" status -b main) >"$T/out" 2>&1
check "the table is unchanged" grep -qE '^feat/a +feat-a +- +- +w5$' "$T/out"

echo "status -j: plan_detail"
setup
plan "$wt" 2 running Parse Writer Docs
run status -j -b main
check "the label stays in plan" jqt 'select(.branch == "feat/a") | .plan == "stage 2/3 running"'
check "stages are done, current, todo" \
  jqt 'select(.branch == "feat/a") | .plan_detail == {status: "running",
       stages: [{n: 1, title: "Parse", state: "done"}, {n: 2, title: "Writer", state: "current"},
                {n: 3, title: "Docs", state: "todo"}], stopped_reason: null}'
plan "$wt" 2 blocked Parse Writer Docs; run status -j -b main
check "blocked: the stage is stopped, with a reason" \
  jqt 'select(.branch == "feat/a") | .plan_detail | (.stages | map(.state)) == ["done","stopped","todo"]
       and (.stopped_reason | startswith("blocked"))'
plan "$wt" 3 failed Parse Writer Docs; run status -j -b main
check "failed: stopped, with a reason" \
  jqt 'select(.branch == "feat/a") | .plan_detail | .stages[2].state == "stopped" and (.stopped_reason | startswith("failed"))'
plan "$wt" 1 running Parse Writer
printf '## Stage 1\nSTOPPED: feat/herd-ui not merged\n' >"$wt/.herd/run/PROGRESS.md"
run status -j -b main
check "a STOPPED: line stops the stage and is the reason" \
  jqt 'select(.branch == "feat/a") | .plan_detail | .stages[0].state == "stopped" and .stopped_reason == "feat/herd-ui not merged"'
rm "$wt/.herd/run/PROGRESS.md"
plan "$wt" 2 verified Parse Writer Docs; run status -j -b main
check "verified: the stage is done" jqt 'select(.branch == "feat/a") | .plan_detail.stages | map(.state) == ["done","done","todo"]'
plan "$wt" 2 complete Parse Writer; run status -j -b main
check "complete: every stage done" jqt 'select(.branch == "feat/a") | .plan_detail | .status == "complete" and (.stages | all(.state == "done"))'
plan "$wt" 0 planning; rm "$wt/.herd/run/stages.md"; run status -j -b main
check "planning, no stages yet" jqt 'select(.branch == "feat/a") | .plan_detail == {status: "planning", stages: [], stopped_reason: null}'

# --- herd status -j -a -------------------------------------------------------------------------
echo "status -j -a"
setup
(cd / && "$herd" status -j -a -b main) >"$T/out" 2>"$T/err"; rc=$?
check "runs outside any repo" test "$rc" = 0
check "is one JSON document with generated_at and host" \
  jqt '(.generated_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$")) and (.host | length > 0)'
check "finds every main checkout with streams under ~/git/wt" \
  jqt "[.repos[] | {repo, path}] == [{repo: \"lib\", path: \"$lib\"}, {repo: \"proj\", path: \"$repo\"}]"
check "each repo lists its streams" jqt '.repos[0].streams | map(.branch) == ["fix/c"]'
check "blocked streams come first" jqt '.repos[1].streams | map(.branch) == ["feat/b", "feat/a"]'
check "streams carry the full status -j object" \
  jqt '.repos[1].streams[1] | .ahead == 2 and .pane_id == "w5:p1" and has("plan_detail")'
mkdir -p "$T/git/wt/junk/notgit" "$T/git/wt/proj/stray"
(cd / && "$herd" status -j -a -b main) >"$T/out" 2>"$T/err"
check "skips directories that are not worktrees" jqt '.repos | length == 2'
rm -rf "$T/git/wt"
(cd / && "$herd" status -j -a) >"$T/out" 2>"$T/err"
check "no streams anywhere: an empty repos list" jqt '.repos == []'

# --- herd show -j ------------------------------------------------------------------------------
echo "show -j"
setup
run show -j -b main "$repo" feat/a diff
check "diff: the diff against the base, uncommitted changes to tracked files included" \
  bash -c "jq -e '.truncated == false' '$T/out' >/dev/null && jq -r .text '$T/out' | grep -qx '+two' && jq -r .text '$T/out' | grep -qx '+more'"
run show -j -b main "$repo" feat/a log
check "log: git log --oneline against the base" \
  test "$(jq -j .text "$T/out" | cut -d' ' -f2- | paste -sd'|' -)" = "add two: the sequel|add one"
run show -j -b main "$repo" feat/a progress
check "progress with no PROGRESS.md: empty text" jqt '.text == "" and .truncated == false'
mkdir -p "$wt/.herd/run"; printf '## Stage 1: x\nDid x.\n' >"$wt/.herd/run/PROGRESS.md"
run show -j -b main "$repo" feat/a progress
check "progress: .herd/run/PROGRESS.md" jqt '.text == "## Stage 1: x\nDid x.\n"'
: >"$T/calls"; run show -j -b main "$repo" feat/a screen
check "screen: herdr agent read of the stream's agent, by pane" called "agent read w5:p1 --source recent-unwrapped"
check "...as the text" jqt '.text | startswith("Allow edit of src/x.rs?")'
agents; run show -j -b main "$repo" feat/a screen
check "screen with no agent: empty text" jqt '.text == ""'
run show -b main "$repo" feat/a log
check "without -j it prints the text itself" grep -q 'add one' "$T/out"
run show -j -b main "$wt" feat/a log
check "the repo may be given as one of its worktrees" test "$rc" = 0
head -c 300000 /dev/zero | tr '\0' x >"$wt/big.txt"; git -C "$wt" add big.txt
run show -j -b main "$repo" feat/a diff
check "text is capped at 200 KB and flagged truncated" jqt '.truncated == true and (.text | utf8bytelength) == 204800'

echo "show -j: rejects"
run show -j "$repo" main diff
check "the main branch is not a stream" bash -c "test $rc != 0 && grep -q 'main is not a herd stream' '$T/err'"
run show -j "$repo" other diff
check "nor is a worktree outside ~/git/wt" bash -c "test $rc != 0 && grep -q 'other is not a herd stream' '$T/err'"
run show -j "$lib" feat/a diff
check "nor another repo's stream" test "$rc" != 0
run show -j "$repo" feat/a blame
check "an unknown what" bash -c "test $rc != 0 && grep -q 'diff, progress, screen or log' '$T/err'"
run show -j "$repo" feat/a
check "too few arguments" test "$rc" != 0
run show -j "$T/nope" feat/a diff
check "a repo that doesn't exist" test "$rc" != 0

echo
echo "$pass passed, $fail failed"
((fail == 0))
