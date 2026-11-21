#!/usr/bin/env bash
# Builds a fixed set of 31 `herd plan` runs under <home>/git/wt/proj/, for the golden test in
# tests/plan_status.sh and for timing `herd plan status --json --all` (HOME=<home>). Like a real
# box, most runs are finished: 22 complete or failed, the rest running, blocked, fixing, stopped,
# pending, ready, planning, verified, plus a garbage state file. Every time is fixed (events, state
# mtimes, driver heartbeats), so the output only varies by <home> and the host name.
#
# It also writes <home>/agents.json, what a fake `herdr agent list` returns for these runs.
#
#   bash tests/plan_fixtures.sh <home>
set -euo pipefail
home=${1:?usage: plan_fixtures.sh <home>}
export TZ=UTC GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
repo=$home/proj
mkdir -p "$home/git/wt/proj"
git init -q -b main "$repo"
git -C "$repo" commit -q --allow-empty -m init

# run <branch> <stage> <status> <stage-count>: a worktree with state and stages.md; sets $r.
run() {
  local d=$home/git/wt/proj/${1//\//-} i
  git -C "$repo" worktree add -q -b "$1" "$d"
  r=$d/.herd/run
  mkdir -p "$r"
  printf 'stage=%s\nstatus=%s\npersona=engineer\nkind=claude\nverify=make test\nbase=origin/main\nbgwait=60\n' "$2" "$3" >"$r/state"
  for ((i = 1; i <= $4; i++)); do printf '## Stage %s: Title %s\nverify: check %s\n\nDo part %s.\n\n' "$i" "$i" "$i" "$i"; done >"$r/stages.md"
  [[ $4 -gt 0 ]] || rm -f "$r/stages.md"
}
# ev <time> <stage> <event> <status> [msg]: one events.ndjson line.
ev() {
  if [[ -n ${5:-} ]]; then printf '{"at":"%s","stage":%s,"event":"%s","status":"%s","msg":"%s"}\n' "$@"
  else printf '{"at":"%s","stage":%s,"event":"%s","status":"%s"}\n' "$1" "$2" "$3" "$4"; fi >>"$r/events.ndjson"
}
# story <hour> <stages> [failed-stage]: a run's events, each stage started and verified, one
# minute apart, from 2026-11-16T<hour>:00; a failed stage fails its gate twice instead.
story() {
  local h=$1 n=$2 f=${3:-0} s m=0 t
  # at: the next minute of hour $h, in $t.
  at() { printf -v t '2026-11-16T%s:%02d:00Z' "$h" "$((m += 1))"; }
  ev "2026-11-16T$h:00:00Z" 1 start pending "feat/x"
  for ((s = 1; s <= n; s++)); do
    at; ev "$t" "$s" stage_start running
    if ((s == f)); then
      at; ev "$t" "$s" gate_fail running "make test failed"
      at; ev "$t" "$s" fixup fixing
      at; ev "$t" "$s" gate_fail fixing "still failing"
      at; ev "$t" "$s" failed failed "gave up"
      return
    fi
    at; ev "$t" "$s" verified verified
  done
  at; ev "$t" "$((n + 1))" complete complete
}
# progress <stages>: a PROGRESS.md section per stage.
progress() { local s; for ((s = 1; s <= $1; s++)); do printf '## Stage %s\nDid part %s.\n\n' "$s" "$s"; done >"$r/PROGRESS.md"; }
pr() { printf 'pr_number=%s\npr_url=https://git.example/o/proj/pulls/%s\n' "$1" "$1" >"$r/pr"; }
# A driver a crashed herd left behind: dead pid, an old heartbeat.
dead_driver() { printf 'pid=999999\nhost=%s\nstarted=2026-11-01T00:00:00Z\nheartbeat=2026-11-01T00:10:00Z\n' "${1:-fixture-host}" >"$r/driver"; }

# --- 13 complete -----------------------------------------------------------------------------
for i in 1 2 3 4 5 6 7 8; do
  run "feat/done-$i" $((i % 4 + 2)) complete $((i % 4 + 1))
  story "$(printf %02d "$i")" $((i % 4 + 1)); progress $((i % 4 + 1)); pr "$((100 + i))"
done
# Quotes, backslashes, a tab and non-ASCII in titles, verify and progress; a stage without its
# own verify (falls back to state's); an empty verify line.
run feat/done-odd 4 complete 0
printf '## Stage 1: Say "hi" \\ there\tnow\nverify: grep -q "a\\b" x\n\nbody\n\n## Stage 2 Ünïcødé — ☃\nno verify line here\n\n## Stage 3:\nverify:\n' >"$r/stages.md"
printf '## Stage 1\nquote " backslash \\ tab \t done\n## Stage 2\nsnow ☃\nSTOPPED: is only a word here\n## Stage 3\n' >"$r/PROGRESS.md"
story 09 3
# PROGRESS.md over 16 KiB in one section, cut inside a two-byte character; a repeated section;
# a "## Stage 01" heading that is not stage 1; a heading-less preamble; broken event lines.
run feat/done-big 3 complete 2
{
  printf 'preamble\n## Stage 1\n'
  head -c 16383 /dev/zero | tr '\0' a
  printf '\303\251 tail\n## Notes\nnot a stage\n## Stage 01\nnot stage one\n## Stage 2\nfirst\n## Stage 2\nsecond\n'
} >"$r/PROGRESS.md"
story 10 2
printf 'not json\n[1,2]\n"string"\n' >>"$r/events.ndjson"
# An old run: state and stages only, no events, PROGRESS.md or pr.
run feat/done-old 3 complete 2
# A complete run with a crashed driver's file left behind, and one with no stages.md.
run feat/done-crashed 2 complete 1
story 11 1; dead_driver
run feat/done-nostages 1 complete 0
story 12 0

# --- 9 failed --------------------------------------------------------------------------------
for i in 1 2 3 4 5 6 7; do
  run "fix/failed-$i" $((i % 3 + 1)) failed 3
  story "$(printf %02d $((12 + i)))" 3 $((i % 3 + 1)); progress $((i % 3 + 1))
done
run fix/failed-stopped 2 failed 2
story 20 2 2; progress 2; printf 'STOPPED:   out of budget  \n' >>"$r/PROGRESS.md"
run fix/failed-driver 1 failed 2
story 21 2 1; dead_driver elsewhere

# --- 9 not finished --------------------------------------------------------------------------
run feat/running 2 running 3
story 22 1; ev 2026-11-16T22:05:00Z 2 stage_start running; progress 2
run feat/blocked 1 blocked 2
ev 2026-11-16T23:00:00Z 1 start pending feat/blocked; ev 2026-11-16T23:01:00Z 1 stage_start running
run feat/fixing 2 fixing 3
story 05 1
ev 2026-11-17T05:10:00Z 2 stage_start running; ev 2026-11-17T05:20:00Z 2 gate_fail running "make test failed"
ev 2026-11-17T05:21:00Z 2 fixup fixing
run feat/stopped 1 running 2
printf '## Stage 1\nnotes\nSTOPPED: lab host unreachable\n' >"$r/PROGRESS.md"; dead_driver
run feat/pending 1 pending 2
run feat/ready 1 pending 2
ev 2026-11-17T09:00:00Z 0 start planning feat/ready; ev 2026-11-17T09:05:00Z 1 planned planning 2
ev 2026-11-17T09:05:01Z 1 dry_stop pending
run feat/planning 0 planning 0
run feat/verified 2 verified 3
story 06 2
run feat/garbage 1 running 0
printf 'not a state file\n' >"$r/state"

# Fixed mtimes on every file, so state's mtime (the fallback for started_at and updated_at) is too.
find "$home/git/wt/proj" -path '*/.herd/run/*' -type f -exec touch -t 202611150800.00 {} +

# What herdr says about some of these agents; the complete ones must never be asked.
cat >"$home/agents.json" <<'EOF'
{"result":{"agents":[
  {"name":"feat-running","agent":"claude","agent_status":"working","cwd":"/x","pane_id":"p1"},
  {"name":"feat-blocked","agent":"claude","agent_status":"blocked","cwd":"/x","pane_id":"p2"},
  {"name":"fix-failed-1","agent":"claude","agent_status":"idle","cwd":"/x","pane_id":"p3"},
  {"name":"feat-done-1","agent":"claude","agent_status":"done","cwd":"/x","pane_id":"p4"},
  {"name":"feat-fixing","agent":"claude","agent_status":"working","cwd":"/x","pane_id":"p5"}
]}}
EOF
