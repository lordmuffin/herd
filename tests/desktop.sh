#!/usr/bin/env bash
# Tests for the desktop backend: herd driving the Herdr app through herdr-core (hc) and herdr-app.
# Both are faked on PATH: hc keeps its terminals as JSON files in $T/hc (what `hc get` prints), logs
# every call, and plays the agent (typing "claude" into a shell makes it report idle, a prompt makes
# it work, a wait ends the turn); herdr-app logs its commands and closes a space's terminals. herdr
# itself is a stub that fails, so any call that leaks to the terminal backend shows up.
#
#   bash tests/desktop.sh        (make test runs it)
# shellcheck disable=SC2034  # the globals set here are herd's, read by the functions sourced below
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/.." && pwd)
herd=$root/bin/herd
unset HC_TERMINAL_ID HERD_BACKEND HERDR_PLUGIN_ID HERDR_ENV HERDR_WORKSPACE_ID HERDR_PANE_ID HERDR_TAB_ID
export TERM_PROGRAM="test"
# shellcheck source=/dev/null
source "$herd"
set +e

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; [[ -z ${2:-} ]] || sed 's/^/       /' <<<"$2"; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name" "$(cat "$T/out" "$T/calls" 2>/dev/null)"; fi; }
called() { grep -qF -- "$1" "$T/calls" 2>/dev/null; }
ORIG_PATH=$PATH
jq_quiet() { jq -e "$@" >/dev/null; }

setup() {
  T=$(mktemp -d)
  export HOME=$T XDG_DATA_HOME=$T/xdg
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  repo=$T/proj wt=$T/git/wt/proj/feat-a
  git init -q -b main "$repo" && git -C "$repo" commit -q --allow-empty -m init
  printf 'feat/a @none: do a\n' >"$repo/Tasks.herd"
  mkdir -p "$T/bin" "$T/hc"
  echo 0 >"$T/hc/next"
  : >"$T/calls"
  cat >"$T/bin/hc" <<'EOF'
#!/usr/bin/env bash
# The fake herdr-core. State: $T/hc/<address>.json, one per terminal, as `hc get --json` prints it.
D=$FAKE/hc
echo "hc $*" >>"$FAKE/calls"
file() { # address or name -> its file
  local f; for f in "$D"/t*.json; do [[ -f $f ]] || continue
    jq -e --arg t "$1" '.address == $t or .name == $t' "$f" >/dev/null && { echo "$f"; return; }; done
  echo "hc: no terminal $1" >&2; exit 3
}
set_status() { local f; f=$(file "$1"); jq --arg s "$2" '.status = {app: "claude-code", state: $s}' "$f" >"$f.new" && mv "$f.new" "$f"; }
cmd=$1; shift
case $cmd in
  ls)
    all=0 labels=()
    while (($#)); do case $1 in --all) all=1; shift ;; --label) labels+=("$2"); shift 2 ;; *) shift ;; esac; done
    for f in "$D"/t*.json; do [[ -f $f ]] && cat "$f"; done | jq -s --argjson all "$all" --args '
      {terminals: [.[] | select($all == 1 or .state == "live")
        | select(. as $t | all($ARGS.positional[]; (split("=") as [$k, $v] | $t.labels[$k] == $v)))
        | {address, name, state, cwd, agent: "shell"}]}' "${labels[@]}" ;;
  get) cat "$(file "$1")" ;;
  run)
    name="" cwd="" labels='{}'
    while (($#)); do case $1 in
      --name) name=$2; shift 2 ;; --cwd) cwd=$2; shift 2 ;;
      --label) labels=$(jq --arg kv "$2" '. + ($kv | split("=") as [$k, $v] | {($k): $v})' <<<"$labels"); shift 2 ;;
      *) shift ;; esac; done
    n=$(($(cat "$D/next") + 1)); echo "$n" >"$D/next"
    jq -n --arg a "t$n" --arg n "$name" --arg c "$cwd" --argjson l "$labels" \
      '{address: $a, name: $n, cwd: $c, state: "live", status: null, labels: $l, foreground: {cwd: $c}}' >"$D/t$n.json"
    jq -c '{address, name, cwd, state}' "$D/t$n.json" ;;
  label)
    f=$(file "$1"); shift
    for kv in "$@"; do jq --arg kv "$kv" '.labels += ($kv | split("=") as [$k, $v] | {($k): $v})' "$f" >"$f.new" && mv "$f.new" "$f"; done ;;
  send)
    printf '%s\x1e' "$2" >>"$FAKE/sends"
    if [[ $2 == "'claude'"* ]]; then
      [[ -e $FAKE/no-status ]] || set_status "$1" idle
      echo '{"started":false,"status":"idle"}'
    elif [[ $2 == /clear ]]; then echo '{"started":false,"status":"idle"}'
    else set_status "$1" working; echo '{"started":true,"status":"working"}'; fi ;;
  wait)
    n=$(($(cat "$FAKE/waits" 2>/dev/null || echo 0) + 1)); echo "$n" >"$FAKE/waits"
    if ((n <= ${WAIT_TIMEOUTS:-0})); then echo '{"reason":"timeout","status":"working"}'
    else set_status "$1" "${WAIT_ENDS:-done}"; echo "{\"reason\":\"status\",\"status\":\"${WAIT_ENDS:-done}\"}"; fi ;;
  read) cat "$FAKE/screen" 2>/dev/null ;;
  kill) f=$(file "$1"); jq '.state = "finished"' "$f" >"$f.new" && mv "$f.new" "$f" ;;
  rm) rm -f "$(file "$1")" ;;
  *) echo "fake hc: unexpected $cmd" >&2; exit 2 ;;
esac
EOF
  cat >"$T/bin/herdr-app" <<'EOF'
#!/usr/bin/env bash
echo "herdr-app $*" >>"$FAKE/calls"
[[ -e $FAKE/app-down ]] && { echo '{"error":"Herdr is not running"}'; exit 1; }
if [[ $1 == do && $2 == space.close ]]; then
  for f in "$FAKE"/hc/t*.json; do
    jq -e --arg s "$4" '.labels["herdr.space"] == $s' "$f" >/dev/null || continue
    jq '.state = "finished"' "$f" >"$f.new" && mv "$f.new" "$f"
  done
  echo '{"ok":true}'
fi
EOF
  printf '#!/usr/bin/env bash\necho "herdr $*" >>"$FAKE/calls"; exit 1\n' >"$T/bin/herdr"
  chmod +x "$T/bin/hc" "$T/bin/herdr-app" "$T/bin/herdr"
  export FAKE=$T PATH=$T/bin:$ORIG_PATH WAIT_TIMEOUTS=0 WAIT_ENDS="done"
}
run_herd() { (cd "$repo" && HERD_BACKEND=desktop "$herd" "$@") >"$T/out" 2>&1; rc=$?; }
term() { jq -r "$2" "$(grep -l "\"name\": \"$1\"" "$T"/hc/t*.json | head -1)"; }
sent() { tr '\036' '\n' <"$T/sends" | grep -qF -- "$1"; }

# --- choosing the backend ---------------------------------------------------------------------
echo "picking the backend"
be() { (unset HERD_BACKEND HC_TERMINAL_ID HERDR_PLUGIN_ID TERM_PROGRAM; export "${@?}"; "$herd" backend 2>&1); }
check "nowhere in particular: tui, as before" test "$(be X=1)" = tui
check "a Herdr app terminal (HC_TERMINAL_ID): desktop" test "$(be HC_TERMINAL_ID=t3 TERM_PROGRAM=ghostty)" = desktop
check "a herdr pane inside a herdr-core terminal: tui" test "$(be HC_TERMINAL_ID=t3 TERM_PROGRAM=herdr)" = tui
check "a herdr plugin: tui" test "$(be HC_TERMINAL_ID=t3 HERDR_PLUGIN_ID=lordmuffin.herd)" = tui
check "HERD_BACKEND=desktop overrides" test "$(be HERD_BACKEND=desktop)" = desktop
check "HERD_BACKEND=tui overrides an app terminal" test "$(be HERD_BACKEND=tui HC_TERMINAL_ID=t3)" = tui
check "a bad HERD_BACKEND is refused" bash -c "[[ \$(HERD_BACKEND=gui '$herd' backend 2>&1) == *'desktop or tui'* ]]"

# --- quoting what is typed into the shell -----------------------------------------------------
echo "typing the agent command"
arg="it's a \"model\" \$HOME; \`x\`"
check "shq round-trips through sh" test "$(sh -c "printf %s $(shq "$arg")")" = "$arg"
check "shq round-trips through bash" test "$(bash -c "printf %s $(shq "$arg")")" = "$arg"
if command -v fish >/dev/null; then
  check "shq round-trips through fish" test "$(fish -c "printf %s $(shq "$arg")")" = "$arg"
fi

# --- fan-out ------------------------------------------------------------------------------------
echo "herd fan-out in the app"
setup; run_herd -b main -- --model sonnet
check "exits 0" test "$rc" -eq 0
check "the worktree is at herd's usual place, on its branch" \
  test "$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null)" = feat/a
check "one kept shell, named after the agent, in the checkout, with no parent" \
  bash -c "grep -c '^hc run --bg --json --keep --no-parent --name feat-a --cwd $wt ' '$T/calls' | grep -qx 1"
check "it carries herdr.space and herdr.tab labels, so the app shows it as a new space" \
  bash -c "[[ \$(jq -r '.labels[\"herdr.space\"]' '$T/hc/t1.json') == herd-feat-a-* && \$(jq -r '.labels[\"herdr.tab\"]' '$T/hc/t1.json') == herd-feat-a-*-1 ]]"
check "and herd's own labels" test "$(term feat-a '[.labels.herd, .labels["herd.path"], .labels["herd.branch"], .labels["herd.kind"]] | join(" ")')" = "1 $wt feat/a claude"
check "the agent is typed into the shell with its args" sent "'claude' '--model' 'sonnet'"
check "then the task is sent" sent "do a"
check "the app is not asked to focus anything" bash -c "! grep -q '^herdr-app' '$T/calls'"
check "the terminal herdr is never called" bash -c "! grep -q '^herdr ' '$T/calls'"
check "says where it started" grep -q "started feat-a  (feat/a -> $wt, pane t1)" "$T/out"

echo "an agent that never reports a status"
setup; touch "$T/no-status"
( set -e; repo=$T/proj; backend=desktop; sleep() { :; }
  hd_start feat-a --kind claude --pane "$(hc run --bg --json --name feat-a --cwd "$T" | jq -r .address)" --timeout 0 ) >"$T/out" 2>&1; rc=$?
check "fails and says why" eval 'test $rc -ne 0 && grep -q "did not report a status" "$T/out"'

echo "an agent asking whether to trust its folder"
setup; touch "$T/no-status"
printf ' Quick safety check: Is this a project you created or one you trust?\n ❯ No, exit\n   Yes, I trust this folder\n' >"$T/screen"
( set -e; repo=$T/proj; backend=desktop; hd_ask_wait=0; sleep() { :; }
  hd_start feat-a --kind claude --pane "$(hc run --bg --json --name feat-a --cwd "$T" --label herdr.space=sp1 --label "herd.path=$T/wt" | jq -r .address)" --timeout 5000 ) >"$T/out" 2>&1; rc=$?
check "says the person has to answer it, and where" grep -q "feat-a asks whether to trust $T/wt — answer it in its space" "$T/out"
check "tells the herd mod, with the space to go to" \
  bash -c "grep '^herdr-app do herd.notice:' '$T/calls' | sed 's/^herdr-app do herd.notice://' | jq -e '.space == \"sp1\" and (.title | test(\"trust\"))' >/dev/null"
check "never answers it itself" bash -c "! grep -qE '^hc (keys|send t1 (y|1|$))' '$T/calls'"
check "gives up once the wait is over" eval 'test $rc -ne 0 && grep -q "nobody answered" "$T/out"'

echo "a terminal closed before its agent started"
setup; touch "$T/no-status"
( set -e; repo=$T/proj; backend=desktop; sleep() { :; }
  t=$(hc run --bg --json --name feat-a --cwd "$T" | jq -r .address); hc kill "$t"
  hd_start feat-a --kind claude --pane "$t" --timeout 600000 ) >"$T/out" 2>&1; rc=$?
check "stops at once instead of waiting out the timeout" eval 'test $rc -ne 0 && grep -q "ended before the agent started" "$T/out"'

# --- status, wait, rm --------------------------------------------------------------------------
echo "herd status and -w in the app"
setup; run_herd -b main -w
check "-w waits for the agent and reports how it ended" grep -qE '^  feat-a: done$' "$T/out"
mkdir -p "$wt/.herd/run"; printf 'stage=2\nstatus=running\n' >"$wt/.herd/run/state"
printf '## Stage 1: a\n## Stage 2: b\n## Stage 3: c\n' >"$wt/.herd/run/stages.md"
(cd "$repo" && HERD_BACKEND=desktop "$herd" status -j) >"$T/out" 2>&1
check "status -j: branch, agent, live status, plan stage and the space" \
  jq_quiet --arg sp "$(term feat-a '.labels["herdr.space"]')" \
    'select(.branch == "feat/a") | .agent == "feat-a" and .status == "done" and .plan == "stage 2/3 running" and .workspace == $sp' "$T/out"
(cd "$repo" && HERD_BACKEND=desktop "$herd" ls) >"$T/out" 2>&1
check "herd ls lists the agent" grep -qE '^feat-a +claude-code +done +' "$T/out"

echo "hc wait checking in"
setup; run_herd -b main
( backend=desktop; WAIT_TIMEOUTS=2 hd_wait feat-a ) >"$T/out" 2>&1
check "timeouts are waited through, then the status is read" \
  eval 'jq -e ".result.agent.agent_status == \"done\"" "$T/out" >/dev/null && test "$(cat "$T/waits")" -eq 3'

echo "herd rm in the app"
setup; run_herd -b main; sp=$(term feat-a '.labels["herdr.space"]')
run_herd rm feat/a
check "exits 0" test "$rc" -eq 0
check "closes the stream's space, confirmed" called "herdr-app do space.close --id $sp --confirmed true"
check "removes the worktree and its branch" \
  eval '! test -d "$wt" && ! git -C "$repo" show-ref --quiet --verify refs/heads/feat/a'
check "clears the finished terminal" eval '! ls "$T"/hc/t*.json >/dev/null 2>&1'

setup; run_herd -b main; touch "$T/app-down"; run_herd rm feat-a
check "with the app closed, ends the space's terminals itself" eval 'test $rc -eq 0 && called "hc kill t1" && ! test -d "$wt"'

echo "what the app can't do yet"
setup; run_herd -b main -m vps -r /srv/proj feat/x "do x"
check "-m is refused with the desktop backend" eval 'test $rc -ne 0 && grep -q "not supported with the Herdr app" "$T/out"'

echo "$pass passed, $fail failed"
((fail == 0))
