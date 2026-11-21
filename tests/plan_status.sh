#!/usr/bin/env bash
# Tests for `herd plan status`: run directories built by hand under $HOME/git/wt/<repo>/<dir>,
# one per case, read back with --json and checked field by field.
#
#   bash tests/plan_status.sh        (make test runs it)
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
herd=$(cd "$here/.." && pwd)/bin/herd
unset HERDR_BIN_PATH HERDR_SOCKET_PATH HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_PANE_ID HERD_RELAY_HOST
export HERD_BACKEND=tui

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; [[ -z ${2:-} ]] || sed 's/^/       /' <<<"$2"; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name" "$(cat "$T/out" 2>/dev/null)"; fi; }
# jqt <branch> <filter>: the filter is true for that branch's plan object.
jqt() { [[ $(jq -r --arg b "$1" ".plans[] | select(.branch == \$b) | ($2)" "$T/out") == true ]]; }

T=$(mktemp -d)
export HOME=$T GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
repo=$T/proj
git init -q -b main "$repo" && git -C "$repo" commit -q --allow-empty -m init
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
ago() { date -u -d "@$(($(date +%s) - $1))" +%Y-%m-%dT%H:%M:%SZ; }

# mk <branch> <stage> <status> [stage-count]: a worktree with state and stages.md; sets $run.
mk() {
  local b=$1 d=$T/git/wt/proj/${1//\//-} i
  git -C "$repo" worktree add -q -b "$b" "$d"
  mkdir -p "$d/.herd/run"
  printf 'stage=%s\nstatus=%s\npersona=engineer\nkind=claude\nverify=make test\nbase=origin/main\nbgwait=60\n' "$2" "$3" >"$d/.herd/run/state"
  if [[ ${4:-0} -gt 0 ]]; then
    for ((i = 1; i <= $4; i++)); do printf '## Stage %s: Title %s\nverify: check %s\n\nbody\n\n' "$i" "$i" "$i"; done >"$d/.herd/run/stages.md"
  fi
  run=$d/.herd/run
}
ev() { jq -nc --arg at "$1" --argjson s "$2" --arg e "$3" --arg st "$4" --arg m "${5:-}" \
  '{at: $at, stage: $s, event: $e, status: $st} + (if $m == "" then {} else {msg: $m} end)' >>"$run/events.ndjson"; }

# One run per status, each on stage 2 of 3 (planning on stage 0 with no stages).
mk feat/planning 0 planning
for st in pending running fixing blocked failed verified; do mk "feat/$st" 2 "$st" 3; done
mk feat/complete 4 complete 3

# The full story: stage 1 clean, stage 2 failed its gate once, then got a fix-up turn.
mk feat/story 2 fixing 3
printf '## Stage 1: Title 1\nDid one.\n\n## Stage 2: Title 2\nwip\n' >"$run/PROGRESS.md"
ev 2026-11-16T10:00:00Z 1 start pending feat/story
ev 2026-11-16T10:01:00Z 1 stage_start running
ev 2026-11-16T10:05:00Z 1 verified verified
ev 2026-11-16T10:06:00Z 2 stage_start running
ev 2026-11-16T10:20:00Z 2 gate_fail running "make test failed"
ev 2026-11-16T10:21:00Z 2 fixup fixing
echo 'this line is not json' >>"$run/events.ndjson"
printf 'pr_number=17\npr_url=https://git.example/o/r/pulls/17\n' >"$run/pr"

# An old run: state only, no stages.md, events, driver or pr.
mk feat/old 1 running
# A STOPPED line, and a dead driver pid on the same run.
mk feat/stopped 1 running 2
printf '## Stage 1: Title 1\nnotes\nSTOPPED: lab host unreachable\n' >"$run/PROGRESS.md"
printf 'pid=999999\nhost=%s\nstarted=%s\nheartbeat=%s\n' "$(hostname -s)" "$(now)" "$(now)" >"$run/driver"
# A live driver: a process with herd in its name, this host, a fresh heartbeat; then a stale
# heartbeat and another host's driver.
(exec -a herd-fake sleep 60) &
live=$!
mk feat/alive 1 running 1
printf 'pid=%s\nhost=%s\nstarted=%s\nheartbeat=%s\n' "$live" "$(hostname -s)" "$(now)" "$(now)" >"$run/driver"
mk feat/stale 1 running 1
printf 'pid=%s\nhost=%s\nstarted=%s\nheartbeat=%s\n' "$live" "$(hostname -s)" "$(ago 600)" "$(ago 600)" >"$run/driver"
mk feat/otherhost 1 running 1
printf 'pid=%s\nhost=elsewhere\nstarted=%s\nheartbeat=%s\n' "$live" "$(now)" "$(now)" >"$run/driver"
# A finished -n planner run, and a state file that is garbage.
mk feat/ready 1 pending 2
ev 2026-11-16T09:00:00Z 0 start planning feat/ready
ev 2026-11-16T09:05:00Z 1 planned planning 2
ev 2026-11-16T09:05:01Z 1 dry_stop pending
mk feat/garbage 1 running
printf 'not a state file\n' >"$run/state"

run_status() { (cd "$repo" && "$herd" plan status "$@") >"$T/out" 2>"$T/err"; rc=$?; }

echo "json shape"
run_status --json
check "exits 0" test "$rc" -eq 0
check "one object, version 1, this host" \
  eval '[[ $(jq -s length "$T/out") == 1 && $(jq -r .version "$T/out") == 1 && $(jq -r .host "$T/out") == "$(hostname -s)" ]]'
check "every plan has the documented keys" eval 'jq -e ".plans | all(has(\"branch\",\"agent\",\"worktree\",\"repo\",\"status\",\"stage\",\"total\",\"persona\",\"kind\",\"base\",\"verify\",\"started_at\",\"updated_at\",\"driver\",\"agent_status\",\"stopped\",\"ready\",\"pr\",\"stages\",\"last_event\"))" "$T/out" >/dev/null'
check "sorted by updated_at, newest first" eval '[[ $(jq -r "[.plans[].updated_at] | . == (sort | reverse)" "$T/out") == true ]]'

echo "statuses and stage rules"
check "planning: no stages, total 0" jqt feat/planning '.status == "planning" and .stages == [] and .total == 0 and .stage == 0'
for st in pending running fixing blocked failed verified; do
  check "$st: stage 1 verified, stage 2 is $st, stage 3 pending" \
    jqt "feat/$st" ".status == \"$st\" and .total == 3 and ([.stages[].status] == [\"verified\", \"$st\", \"pending\"])"
done
check "complete: every stage verified" jqt feat/complete '[.stages[].status] == ["verified","verified","verified"]'
check "titles and verify from stages.md, the rest from state" \
  jqt feat/pending '.stages[0].title == "Title 1" and .stages[0].verify == "check 1" and .persona == "engineer" and .kind == "claude" and .base == "origin/main" and .verify == "make test"'
check "worktree, repo and agent" \
  jqt feat/pending '(.worktree | endswith("/git/wt/proj/feat-pending")) and .repo == "proj" and .agent == "feat-pending"'

echo "events: times, attempts and gate"
run_status --json feat/story
check "one plan for one branch" eval '[[ $(jq ".plans | length" "$T/out") == 1 ]]'
check "started_at and updated_at from the events" \
  jqt feat/story '.started_at == "2026-11-16T10:00:00Z" and .updated_at == "2026-11-16T10:21:00Z"'
check "stage 1: started, ended, one attempt, gate ok" \
  jqt feat/story '.stages[0] | .started_at == "2026-11-16T10:01:00Z" and .ended_at == "2026-11-16T10:05:00Z" and .attempts == 1 and .gate == {ok: true, at: "2026-11-16T10:05:00Z", message: null}'
check "stage 2: two attempts, gate failed with its message, not ended" \
  jqt feat/story '.stages[1] | .attempts == 2 and .ended_at == null and .gate == {ok: false, at: "2026-11-16T10:20:00Z", message: "make test failed"}'
check "progress is the stage's section without its heading" \
  jqt feat/story '.stages[0].progress == "Did one.\n\n" and .stages[1].progress == "wip\n" and .stages[2].progress == null'
check "last_event" jqt feat/story '.last_event == {at: "2026-11-16T10:21:00Z", event: "fixup", msg: null}'
check "a broken events line is skipped, not an error" jqt feat/story 'has("error") | not'
check "pr from the pr file" jqt feat/story '.pr == {number: 17, url: "https://git.example/o/r/pulls/17"}'

echo "old runs and bad input"
run_status --json feat/old
check "no files: no stages, events or pr" jqt feat/old '.stages == [] and .last_event == null and .pr == null and .total == 0'
check "started_at and updated_at fall back to state's mtime" \
  jqt feat/old '(.started_at | test("^[0-9]{4}-.*Z$")) and .started_at == .updated_at'
run_status --json feat/garbage
check "garbage state: still exits 0, with an error entry" test "$rc" -eq 0 && jqt feat/garbage '.error != null and .branch == "feat/garbage"'

echo "driver"
run_status --json
check "missing driver: alive false, rest null" jqt feat/old '.driver == {alive: false, pid: null, host: null, heartbeat_at: null}'
check "dead pid is not alive, but is reported" jqt feat/stopped '.driver.alive == false and .driver.pid == 999999'
check "live herd process, this host, fresh heartbeat is alive" jqt feat/alive '.driver.alive == true and .driver.pid != null'
check "a stale heartbeat is not alive" jqt feat/stale '.driver.alive == false'
check "another host's driver is not alive" jqt feat/otherhost '.driver.alive == false and .driver.host == "elsewhere"'

echo "stopped and ready"
check "stopped carries the STOPPED line's reason" jqt feat/stopped '.stopped == "lab host unreachable"'
check "others are not stopped" jqt feat/story '.stopped == null'
check "a finished -n run is ready" jqt feat/ready '.ready == true and .last_event.event == "dry_stop"'
check "an ordinary pending run is not" jqt feat/pending '.ready == false'

echo "agent_status"
check "null when herdr can't say" jqt feat/running '.agent_status == null'
mkdir -p "$T/bin"
cat >"$T/bin/herdr" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$HOME/calls"
[[ "$1 $2" == "agent list" ]] && echo '{"result":{"agents":[{"name":"feat-running","agent_status":"working"},{"name":"feat-complete","agent_status":"done"}]}}'
[[ "$1 $2" == "worktree list" ]] && exit 1
exit 0
FAKE
chmod +x "$T/bin/herdr"
PATH=$T/bin:$PATH run_status --json
check "taken from herdr agent list" jqt feat/running '.agent_status == "working"'
check "complete runs are not asked" jqt feat/complete '.agent_status == null'
check "agents herdr doesn't list are null" jqt feat/blocked '.agent_status == null'
check "herdr was asked agent list, once for all runs" eval '[[ $(cat "$T/calls") == "agent list" ]]'
printf '#!/usr/bin/env bash\nsleep 30\n' >"$T/bin/herdr"
start=$SECONDS
PATH=$T/bin:$PATH run_status --json feat/running
check "a hung herdr is cut off after about 3s" test $((SECONDS - start)) -lt 10 -a "$rc" -eq 0
rm -f "${T:?}/bin/herdr"

echo "selecting runs"
run_status --json feat/story feat/old
check "named branches only" eval '[[ $(jq -c "[.plans[].branch] | sort" "$T/out") == "[\"feat/old\",\"feat/story\"]" ]]'
run_status --json nope
check "an unknown branch: noted on stderr, exit 1, valid JSON" \
  eval '[[ $rc -eq 1 ]] && grep -q "no plan run for nope" "$T/err" && jq -e ".plans == []" "$T/out" >/dev/null'
run_status --json --all
check "--all reads every worktree under ~/git/wt" eval '[[ $(jq ".plans | length" "$T/out") -ge 15 ]]'
run_status --json
check "default: the current repo's runs" eval '[[ $(jq ".plans | length" "$T/out") -ge 15 ]]'
run_status
check "the table has a header and a row per run" \
  eval 'grep -q "^BRANCH" "$T/out" && grep -Eq "feat/story +2/3 +fixing +no driver" "$T/out"'

echo "plan stop"
run_stop() { (cd "$repo" && "$herd" plan stop "$@") >"$T/out" 2>"$T/err"; rc=$?; }
mk feat/tostop 1 running 1
printf '## Stage 1: Title 1\nnotes\n' >"$run/PROGRESS.md"
run_stop feat/tostop lab host is down
check "appends STOPPED with the reason" eval '[[ $rc -eq 0 ]] && [[ $(grep -c "^STOPPED:" "$run/PROGRESS.md") -eq 1 ]] && grep -qx "STOPPED: lab host is down" "$run/PROGRESS.md"'
run_stop feat/tostop again
check "a second stop does not add another line" eval '[[ $rc -eq 0 ]] && [[ $(grep -c "^STOPPED:" "$run/PROGRESS.md") -eq 1 ]] && grep -q "already stopped" "$T/out"'
run_status --json feat/tostop
check "status sees the stop reason" jqt feat/tostop '.stopped == "lab host is down"'
mk feat/defaultreason 1 running 1
run_stop feat/defaultreason
check "default reason" grep -qx "STOPPED: stopped by herd plan stop" "$run/PROGRESS.md"
check "without --kill the driver is left alone" kill -0 "$live"
(exec -a herd-fake2 sleep 60) &
victim=$!
mk feat/tokill 1 running 1
printf 'pid=%s\nhost=%s\nstarted=%s\nheartbeat=%s\n' "$victim" "$(hostname -s)" "$(now)" "$(now)" >"$run/driver"
run_stop --kill feat/tokill
sleep 0.3
check "--kill signals the driver, adds the line and logs a stopped event" eval '
  [[ $rc -eq 0 ]] && ! kill -0 "$victim" 2>/dev/null && grep -q "^STOPPED:" "$run/PROGRESS.md" &&
  [[ $(jq -r "select(.event == \"stopped\") | .stage" "$run/events.ndjson") == 1 ]]'
mk feat/nokill 1 running 1
run_stop --kill feat/nokill
check "--kill with no live driver still stops the run" eval '[[ $rc -eq 0 ]] && grep -q "^STOPPED:" "$run/PROGRESS.md" && grep -q "no live driver" "$T/out"'
run_stop nope
check "a missing run exits 1" eval '[[ $rc -eq 1 ]] && grep -q "no plan run for nope" "$T/err"'
run_stop
check "no branch is a usage error" eval '[[ $rc -ne 0 ]] && grep -q "needs a branch" "$T/err"'

echo "golden: --all over tests/plan_fixtures.sh's runs"
# The JSON must stay byte for byte what tests/fixtures/plan_status.golden.json holds (made by the
# implementation before the fast one), with the fixtures' home and this host's name masked.
# HERD_GOLDEN_UPDATE=1 rewrites it instead, for a deliberate change to the output.
G=$T/golden
bash "$here/plan_fixtures.sh" "$G" >/dev/null 2>&1
golden=$here/fixtures/plan_status.golden.json
mkdir -p "$G/bin"
cat >"$G/bin/herdr" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >>"$HOME/calls"
case "$1 $2" in
  "agent list") cat "$HOME/agents.json" ;;
  "agent get") jq -ce --arg n "$3" '{result: {agent: (.result.agents[] | select(.name == $n))}}' "$HOME/agents.json" ;;
  *) exit 1 ;;
esac
FAKE
chmod +x "$G/bin/herdr"
gold() {
  (export HOME=$G PATH=$G/bin:$PATH; cd "$G" && "$herd" plan status --json --all) 2>"$T/err" |
    sed -e "s|$G|@HOME@|g" -e 's|^{"version":1,"host":"[^"]*"|{"version":1,"host":"@HOST@"|' >"$T/out"
}
gold
if [[ -n ${HERD_GOLDEN_UPDATE:-} ]]; then cp "$T/out" "$golden"; echo "  (rewrote $golden)"; fi
check "the first call matches the golden JSON" cmp -s "$T/out" "$golden"
check "31 runs" eval '[[ $(jq ".plans | length" "$T/out") == 31 ]]'
check "herdr is asked once, with agent list" eval '[[ $(cat "$G/calls") == "agent list" ]]'
rm -f "$G/calls"
gold
check "a second, cached call matches it too" cmp -s "$T/out" "$golden"
check "finished runs are cached, live ones are not" eval '
  [[ -s $G/git/wt/proj/feat-done-1/.herd/run/status.json && -s $G/git/wt/proj/fix-failed-1/.herd/run/status.json ]] &&
  [[ ! -e $G/git/wt/proj/feat-running/.herd/run/status.json && ! -e $G/git/wt/proj/feat-stopped/.herd/run/status.json ]]'
check "the cache keeps agent_status live for failed runs" jqt fix/failed-1 '.agent_status == "idle"'
jq -c '.result.agents[2].agent_status = "working"' "$G/agents.json" >"$G/agents.tmp" && mv "$G/agents.tmp" "$G/agents.json"
gold
check "a failed run's agent_status follows herdr, cached or not" jqt fix/failed-1 '.agent_status == "working"'
printf '{"at":"2026-11-18T00:00:00Z","stage":3,"event":"note","status":"complete"}\n' \
  >>"$G/git/wt/proj/feat-done-1/.herd/run/events.ndjson"
gold
check "a changed file is read again, not taken from the cache" \
  jqt feat/done-1 '.updated_at == "2026-11-18T00:00:00Z" and .last_event.event == "note"'
printf 'garbage\n' >"$G/git/wt/proj/feat-done-2/.herd/run/status.json"
gold
check "a status.json that isn't ours is ignored" jqt feat/done-2 '.status == "complete" and .stages[0].title == "Title 1"'
c3=$G/git/wt/proj/feat-done-3/.herd/run/status.json
sed -i 's/"stages":\[/"stages":[[[/' "$c3"
gold
check "a status.json with the right key but broken JSON is dropped and read afresh" eval '
  jqt feat/done-3 ".status == \"complete\" and .stages[0].title == \"Title 1\"" && jq -e .plan.stages "$c3" >/dev/null'

kill "$live"
echo "$pass passed, $fail failed"
((fail == 0))
