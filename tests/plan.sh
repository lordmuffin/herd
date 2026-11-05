#!/usr/bin/env bash
# Tests for herd plan's stage loop: background work, the gate, fix-up turns and STOPPED.
# herdr is faked (h), so no agent runs; the "agent" is a script that does a stage's work on cue.
#
#   bash tests/plan.sh        (make test runs it)
# shellcheck disable=SC2034  # the globals set here are herd's, read by the functions sourced below
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
fixtures=$here/fixtures
# shellcheck source=/dev/null
source "$here/../bin/herd"
set +e

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; [[ -z ${2:-} ]] || sed 's/^/       /' <<<"$2"; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name" "$(cat "$T/out" 2>/dev/null)"; fi; }
count() { if [[ -f $1 ]]; then wc -l <"$1" | tr -d ' '; else echo 0; fi; }

# --- the fake ---------------------------------------------------------------------------------
# READS: one word per `agent read` (busy|busy2|idle), the last one repeats.
# WORK_AT_READ=k: the agent finishes the stage on read k (its background job just ended).
# WORK_ON_PROMPT=k: the agent finishes the stage during its k-th real prompt (not /clear).
# STOP_ON_PROMPT=k: the agent writes a STOPPED: line during its k-th prompt.
# Counters live in files: h runs in $(...) subshells too.
do_work() {
  echo "done" >"$wt_path/done.txt"
  git -C "$wt_path" add done.txt && git -C "$wt_path" commit -qm "stage 1"
  printf '## Stage 1: Lab run\nRan the lab driver.\n' >>"$run/PROGRESS.md"
  git -C "$wt_path" push -q origin "HEAD:refs/heads/$plan_branch"
}

h() {
  local n w word
  case "$1 $2" in
    "agent wait" | "agent get") echo '{"result":{"agent":{"agent_status":"idle"}}}' ;;
    "agent read")
      echo x >>"$T/reads"; n=$(count "$T/reads")
      read -ra w <<<"$READS"
      word=${w[-1]}; ((n > ${#w[@]})) || word=${w[n-1]}
      [[ $n != "${WORK_AT_READ:-}" ]] || do_work >/dev/null
      case $word in
        busy) cat "$fixtures/claude-busy.txt" ;; busy2) cat "$fixtures/claude-busy-statusline.txt" ;;
        idle) cat "$fixtures/claude-idle.txt" ;;
      esac ;;
    "agent prompt")
      [[ $4 == /clear ]] && return 0
      printf '%s\n\x1e\n' "$4" >>"$T/prompts"; echo x >>"$T/nprompts"; n=$(count "$T/nprompts")
      [[ $n != "${WORK_ON_PROMPT:-}" ]] || do_work >/dev/null
      [[ $n != "${STOP_ON_PROMPT:-}" ]] || echo "STOPPED: lab host unreachable, needs a human" >>"$run/PROGRESS.md"
      ;;
    *) echo "unexpected h $*" >&2; return 1 ;;
  esac
}
sleep() { echo "$1" >>"$T/sleeps"; }

# A one-stage plan in a fresh worktree with a bare origin, so the last-stage push check is real.
setup() {
  T=$(mktemp -d)
  export HOME=$T XDG_DATA_HOME=$T/xdg   # no forgejo-cli keys: the PR check is skipped
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  git init -q --bare "$T/origin.git"
  git init -q -b main "$T/wt"
  git -C "$T/wt" commit -q --allow-empty -m init
  git -C "$T/wt" remote add origin "$T/origin.git"
  echo '.herd/run/' >>"$T/wt/.git/info/exclude"
  wt_path=$T/wt wt_name=test run=$T/wt/.herd/run plan_branch=feat/lab
  kind=claude persona=none base=origin/main plan_verify="" bg_wait=60 bg_poll=30
  stage=1 status=pending
  mkdir -p "$run"
  cat >"$run/stages.md" <<EOF
## Stage 1: Lab run
verify: echo run >>"$T/verify.log"; test -f done.txt

Run the lab driver and record the result.
EOF
  save_state
  READS="idle" WORK_AT_READ="" WORK_ON_PROMPT="" STOP_ON_PROMPT=""
}
run_plan() { (set -e; drive_plan) >"$T/out" 2>&1; rc=$?; }
state() { sed -n "s/^$1=//p" "$run/state"; }
polls() { grep -cx "$bg_poll" "$T/sleeps" 2>/dev/null || true; }   # not fresh_session's sleep 3
fixups() { grep -c 'is not done yet' "$T/prompts" 2>/dev/null || true; }

# --- pane parsing ------------------------------------------------------------------------------
echo "pane footer"
T=$(mktemp -d)
check "claude footer with 1 shell, 1 monitor still running is busy" bg_text_busy <"$fixtures/claude-busy.txt"
check "claude status line with 2 shells is busy" bg_text_busy <"$fixtures/claude-busy-statusline.txt"
check "claude idle footer is not busy" eval '! bg_text_busy <"$fixtures/claude-idle.txt"'
check "transcript mentions above the footer don't count" \
  eval '! bg_text_busy <"$fixtures/claude-idle-transcript-mentions.txt"'

# --- the stage loop -----------------------------------------------------------------------------
echo "busy with background shells/monitors"
setup; READS="busy busy busy2 idle" WORK_AT_READ=4; run_plan
check "plan completes" test "$rc" -eq 0 -a "$(state status)" = complete
check "the gate ran once, after the job finished" test "$(count "$T/verify.log")" -eq 1
check "herd re-checked on the poll interval while busy" test "$(polls)" -ge 3
check "no fix-up turn was sent" test "$(fixups)" -eq 0
check "the stage prompt carries the turn rule" grep -q 'Never end a turn while a job, Monitor or eval' "$T/prompts"

echo "idle and done"
setup; WORK_ON_PROMPT=1; run_plan
check "plan completes" test "$rc" -eq 0 -a "$(state status)" = complete
check "gated once, with no wait" test "$(count "$T/verify.log")" -eq 1 -a "$(polls)" -eq 0
check "no fix-up turn was sent" test "$(fixups)" -eq 0

echo "idle and not done"
setup; run_plan
check "stops after one fix-up turn" grep -q 'still fails after a fix-up turn' "$T/out"
check "exit 1, state failed" test "$rc" -eq 1 -a "$(state status)" = failed
check "exactly one fix-up turn" test "$(fixups)" -eq 1

echo "fix-up turn that leaves background work running"
setup; READS="idle idle busy busy idle" WORK_AT_READ=5; run_plan
check "is waited out, not counted as the second failure" test "$rc" -eq 0 -a "$(state status)" = complete
check "one fix-up turn, gate ran twice" test "$(fixups)" -eq 1 -a "$(count "$T/verify.log")" -eq 2

echo "background work picked up while the gate ran"
setup; READS="idle busy idle" WORK_AT_READ=3; run_plan
check "plan completes" test "$rc" -eq 0 -a "$(state status)" = complete
check "no fix-up turn was sent" test "$(fixups)" -eq 0

echo "background work past the -W cap"
setup; READS="busy"; bg_wait=0; run_plan
check "stops with exit 3 and the reason" test "$rc" -eq 3 && grep -q 'background work running after 0 min' "$T/out"
check "not a failed gate: status still running, gate never ran" \
  test "$(state status)" = running -a "$(count "$T/verify.log")" -eq 0
check "no fix-up turn was sent" test "$(fixups)" -eq 0

echo "STOPPED line in PROGRESS.md"
setup; STOP_ON_PROMPT=1; run_plan
check "stops with exit 1 and the line as the reason" \
  test "$rc" -eq 1 && grep -q 'STOPPED: lab host unreachable, needs a human' "$T/out"
check "no fix-up turn, gate never ran" test "$(fixups)" -eq 0 -a "$(count "$T/verify.log")" -eq 0
check "state keeps its status for -R" test "$(state status)" = running

echo "$pass passed, $fail failed"
((fail == 0))
