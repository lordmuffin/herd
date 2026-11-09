#!/usr/bin/env bash
# Tests for herd serve (serve/herd_serve.py, started through `herd serve`): tokens, auth, the
# Host check, the snapshot and show routes, the event stream and a clean SIGTERM. The server runs
# on a free port against a temp repo and the same faked herdr as tests/status.sh; curl is the
# client.
#
#   bash tests/serve.sh        (make test runs it)
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/.." && pwd)
herd=$root/bin/herd
# Run inside a herdr pane, these would reach the real herdr and its workspaces.
unset HERDR_BIN_PATH HERDR_SOCKET_PATH HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_PANE_ID HERD_RELAY_HOST \
  HERDR_PLUGIN_CONFIG_DIR XDG_STATE_HOME XDG_CONFIG_HOME HERD_STATE_DIR

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; [[ -z ${2:-} ]] || sed 's/^/       /' <<<"$2"; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name" "$(cat "$T/out" "$T/log" 2>/dev/null)"; fi; }
jqt() { jq -e "$1" "$T/out" >/dev/null 2>&1; }

# A repo proj with one stream, feat/a (a real worktree at ~/git/wt/proj/feat-a), an agent on it,
# and herd.conf at $HERD_CONF. herdr answers worktree list and agent list from $T/*.json.
setup() {
  T=$(mktemp -d)
  export HOME=$T HERD_CONF=$T/herd.conf
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  repo=$T/proj wt=$T/git/wt/proj/feat-a state=$T/.local/state/herd
  git init -q -b main "$repo" && git -C "$repo" commit -q --allow-empty -m init
  git -C "$repo" worktree add -q -b feat/a "$wt"
  echo one >"$wt/one.txt"; git -C "$wt" add one.txt; git -C "$wt" commit -q -m "add one"
  printf 'HERD_BASE=main\n' >"$HERD_CONF"
  cat >"$T/wt.json" <<EOF
{"result":{"worktrees":[
  {"path":"$repo","branch":"main","is_linked_worktree":false,"open_workspace_id":"w1"},
  {"path":"$wt","branch":"feat/a","is_linked_worktree":true,"open_workspace_id":"w5"}]}}
EOF
  agent working
  mkdir -p "$T/bin"
  cat >"$T/bin/herdr" <<EOF
#!/usr/bin/env bash
case "\$1 \$2" in
  "worktree list") cat "$T/wt.json" ;;
  "agent list") cat "$T/agents.json" ;;
  "agent read") printf 'Allow edit of src/x.rs?\n' ;;
  *) exit 1 ;;
esac
EOF
  chmod +x "$T/bin/herdr"
  export PATH=$T/bin:$ORIG_PATH
}
ORIG_PATH=$PATH

agent() { # status: the one agent, on feat/a
  printf '{"result":{"agents":[{"agent":"claude","name":"feat-a","pane_id":"w5:p1","cwd":"%s","agent_status":"%s"}]}}\n' \
    "$wt" "$1" >"$T/agents.json"
}

free_port() { python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])'; }

# start [herd serve flags]: the server in the background on a free port, up once /healthz answers.
start() {
  port=$(free_port)
  "$herd" serve --port "$port" "$@" >"$T/log" 2>&1 &
  pid=$!
  local i
  for ((i = 0; i < 100; i++)); do
    curl -fs "http://127.0.0.1:$port/healthz" >/dev/null 2>&1 && return 0
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
  done
  return 1
}

stop() { kill -TERM "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; }

# get <path> [curl args]: GET from the server; the body goes to $T/out and the status to $code.
get() {
  local p=$1; shift
  code=$(curl -s -o "$T/out" -w '%{http_code}' --max-time 10 "$@" "http://127.0.0.1:$port$p")
}

token() { jq -r ".$1" "$state/serve-tokens.json"; }

# --- start, tokens ------------------------------------------------------------------------------
echo "start"
setup
if ! command -v python3 >/dev/null; then
  echo "  skip: no python3"; echo; echo "0 passed, 0 failed"; exit 0
fi
check "starts on loopback and answers /healthz" start
get /healthz
check "/healthz is ok with no token" test "$code $(cat "$T/out")" = "200 ok"
check "writes the tokens file on first start" test -f "$state/serve-tokens.json"
check "...with mode 0600" test "$(stat -c %a "$state/serve-tokens.json" 2>/dev/null || stat -f %Lp "$state/serve-tokens.json")" = 600
check "...holding two different tokens" bash -c "[[ \$(jq -r '.reader | length' '$state/serve-tokens.json') -ge 40 && \$(jq -r .reader '$state/serve-tokens.json') != \$(jq -r .controller '$state/serve-tokens.json') ]]"
reader=$(token reader) controller=$(token controller)

# --- auth -----------------------------------------------------------------------------------------
echo "auth"
get /api/snapshot
check "/api/snapshot needs a token (401)" test "$code" = 401
get /api/snapshot -H "Authorization: Bearer nope"
check "a wrong token is 401" test "$code" = 401
get /api/snapshot -H "Authorization: Bearer $reader"
check "the reader token works on GET" test "$code" = 200
get /api/snapshot -H "Authorization: Bearer $controller"
check "so does the controller token" test "$code" = 200
get "/api/snapshot?t=$reader"
check "?t= is not accepted outside /api/events" test "$code" = 401
get /api/nope -H "Authorization: Bearer $reader"
check "an unknown /api route is 404" test "$code" = 404
get /api/snapshot -X POST -H "Authorization: Bearer $controller"
check "no write routes yet: POST is 405" test "$code" = 405

echo "Host check"
get /api/snapshot -H "Authorization: Bearer $reader" -H "Host: evil.example:$port"
check "a foreign Host is rejected" test "$code" = 403
get /healthz -H "Host: evil.example"
check "...also on /healthz" test "$code" = 403
get /api/snapshot -H "Authorization: Bearer $reader" -H "Host: localhost:$port"
check "localhost is accepted" test "$code" = 200

# --- routes ---------------------------------------------------------------------------------------
echo "routes"
get /api/snapshot -H "Authorization: Bearer $reader"
check "/api/snapshot is valid JSON from herd status -j -a" jqt '.generated_at and (.repos | type == "array")'
check "...with the fixture's stream" \
  jqt ".repos == [.repos[0]] and .repos[0].path == \"$repo\" and .repos[0].streams[0].branch == \"feat/a\"
       and .repos[0].streams[0].status == \"working\" and .repos[0].streams[0].pane_id == \"w5:p1\""
check "...against HERD_BASE from herd.conf" jqt '.repos[0].streams[0].ahead == 1'
get "/api/show?repo=$repo&branch=feat/a&what=log" -H "Authorization: Bearer $reader"
check "/api/show serves herd show -j" bash -c "test $code = 200 && jq -r .text '$T/out' | grep -q 'add one'"
get "/api/show?repo=$repo&branch=feat/a&what=screen" -H "Authorization: Bearer $reader"
check "...the screen too" jqt '.text | startswith("Allow edit")'
get "/api/show?repo=$T&branch=feat/a&what=log" -H "Authorization: Bearer $reader"
check "a repo that's not in the snapshot is 404" test "$code" = 404
get "/api/show?repo=$repo&branch=main&what=log" -H "Authorization: Bearer $reader"
check "...and so is a branch that's not a stream" test "$code" = 404
get "/api/show?repo=$repo&branch=feat/a&what=blame" -H "Authorization: Bearer $reader"
check "an unknown what is 400" test "$code" = 400
get "/api/show?repo=$repo&branch=feat/a&what=log"
check "/api/show needs a token" test "$code" = 401
get /
check "/ serves web/index.html" bash -c "test $code = 200 && grep -q '<title>herd</title>' '$T/out'"
get /static/index.html
check "/static/* serves web/" test "$code" = 200
get /static/../bin/herd --path-as-is
check "/static/ can't climb out of web/" test "$code" = 404

# --- events ---------------------------------------------------------------------------------------
echo "events"
get /api/events --max-time 2
check "/api/events needs a token" test "$code" = 401
curl -sN --max-time 2 "http://127.0.0.1:$port/api/events?t=$reader" >"$T/out" 2>/dev/null
check "/api/events takes ?t= and sends a snapshot event at once" grep -qx 'event: snapshot' "$T/out"
check "...whose data is the snapshot" \
  bash -c "sed -n 's/^data: //p' '$T/out' | head -1 | jq -e '.repos[0].streams[0].branch == \"feat/a\"' >/dev/null"
check "the token never reaches the log" bash -c "! grep -qF -- '$reader' '$T/log'"
check "...though the request is logged" grep -q 'GET /api/events' "$T/log"
# A status change plus a nudge reaches an open stream well before the 5 s poll.
{ sleep 0.8; agent blocked; touch "$state/serve.nudge"; } &
curl -sN --max-time 2.5 -H "Authorization: Bearer $reader" "http://127.0.0.1:$port/api/events" >"$T/out" 2>/dev/null
wait $!
check "a nudge sends the changed snapshot at once" \
  bash -c "test \$(grep -cx 'event: snapshot' '$T/out') = 2 && sed -n 's/^data: //p' '$T/out' | tail -1 | jq -e '.repos[0].streams[0].status == \"blocked\"' >/dev/null"

# --- stop -----------------------------------------------------------------------------------------
echo "stop"
kill -TERM "$pid"
for ((i = 0; i < 50; i++)); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
wait "$pid"; rc=$?
check "exits cleanly on SIGTERM" test "$rc" = 0
check "...and says so" grep -q 'stopped' "$T/log"

echo "listen"
start --read-only; rc=$?
check "--read-only starts and says so" bash -c "test $rc = 0 && grep -q read-only '$T/log'"
stop
printf 'HERD_BASE=main\nHERD_SERVE_LISTEN=0.0.0.0\n' >"$HERD_CONF"
"$herd" serve --port "$(free_port)" >"$T/log" 2>&1; rc=$?
check "a non-loopback HERD_SERVE_LISTEN alone is refused" bash -c "test $rc != 0 && grep -q 'pass --listen' '$T/log'"
rm "$state/serve-tokens.json"
"$herd" serve --listen 0.0.0.0 --port "$(free_port)" >"$T/log" 2>&1; rc=$?
check "an explicit non-loopback --listen without tokens is refused" bash -c "test $rc != 0 && grep -q 'without tokens' '$T/log'"
check "...and writes no tokens" test ! -e "$state/serve-tokens.json"
"$herd" serve --port x >"$T/log" 2>&1; rc=$?
check "a bad --port is refused" test "$rc" != 0

rm -rf "$T"
echo
echo "$pass passed, $fail failed"
((fail == 0))
