#!/usr/bin/env bash
# Tests for herd serve (serve/herd_serve.py, started through `herd serve`): tokens, auth, the
# Host check, the snapshot and show routes, the event stream, the write routes, a clean SIGTERM,
# and herd serve pair, revoke, install and uninstall. The server runs on a free port against a
# temp repo and the same faked herdr as tests/status.sh; curl is the client. The write routes run
# a fake herd that only logs what it was asked to do, so no agent ever starts; systemctl,
# launchctl and qrencode are fakes too, and install writes under the temp HOME.
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
  "plugin pane") printf '%s\n' "\$*" >>"$T/herdr.calls" ;;
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
check "POST to a read route is 404" test "$code" = 404
get /api/snapshot -X PUT -H "Authorization: Bearer $controller"
check "PUT is 405" test "$code" = 405

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

# --- the page ---------------------------------------------------------------------------------------
echo "page"
# ctype <path>: GET it and set $ctype to its Content-Type.
ctype() { ctype=$(curl -s -o "$T/out" -w '%{content_type}' --max-time 10 "http://127.0.0.1:$port$1"); }
get /
check "/ is the page, with its script, stylesheet and manifest" \
  bash -c "grep -q 'src=\"/static/app.js\"' '$T/out' && grep -q 'href=\"/static/app.css\"' '$T/out' && grep -q 'rel=\"manifest\"' '$T/out'"
ctype /static/app.js
check "app.js is text/javascript" bash -c "[[ '$ctype' == text/javascript* ]] && grep -q EventSource '$T/out'"
ctype /static/app.css
check "app.css is text/css" bash -c "[[ '$ctype' == text/css* ]]"
ctype /static/manifest.webmanifest
check "the manifest is application/manifest+json" bash -c "[[ '$ctype' == application/manifest+json* ]]"
check "...named herd, standalone, with a 192 and a 512 icon" \
  jqt '.name == "herd" and .display == "standalone" and .theme_color and ([.icons[].sizes] | index("192x192") and index("512x512"))'
ok_icons=1
for src in $(jq -r '.icons[].src' "$T/out"); do
  [[ $(curl -s -o /dev/null -w '%{http_code} %{content_type}' "http://127.0.0.1:$port$src") == "200 image/png" ]] || ok_icons=0
done
check "...whose icons are served as PNGs" test "$ok_icons" = 1
ctype /sw.js
check "the service worker is at /sw.js, as text/javascript" bash -c "[[ '$ctype' == text/javascript* ]] && grep -q 'addEventListener(\"fetch\"' '$T/out'"
check "...that skips /api and lists no /api route in its shell" bash -c "grep -qF 'pathname.startsWith(\"/api/\")' '$T/out' && ! sed -n '/^const SHELL/,/];/p' '$T/out' | grep -q /api"
# No CDN, no third-party anything: the page talks to this server only.
check "app.js, sw.js and the page have no external URLs" bash -c "! grep -nE 'https?://|//[a-z0-9.-]+\\.[a-z]{2,}/' '$root/web/app.js' '$root/web/sw.js' '$root/web/index.html' '$root/web/app.css'"

echo "config"
get /api/config
check "/api/config needs a token" test "$code" = 401
get /api/config -H "Authorization: Bearer $reader"
check "/api/config holds only the relay and write settings" jqt 'keys == ["read_only", "relay_app_url", "relay_host", "repos", "role"]'
check "...and which token this is" jqt '.role == "reader" and .read_only == false'
get /api/config -H "Authorization: Bearer $controller"
check "...the controller's too" jqt '.role == "controller"'
check "...with no app URL when herd.conf sets none" jqt '.relay_app_url == null and (.relay_host | length > 0)'
check "...and no token" bash -c "! grep -qF -e '$reader' -e '$controller' '$T/out'"

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

echo "config from herd.conf"
printf 'HERD_BASE=main\nHERD_RELAY_APP_URL=https://relay.example/app/\nHERD_RELAY_HOST=lap\n' >"$HERD_CONF"
start
get /api/config -H "Authorization: Bearer $reader"
check "HERD_RELAY_APP_URL and HERD_RELAY_HOST reach /api/config" \
  jqt '.relay_app_url == "https://relay.example/app/" and .relay_host == "lap"'
check "...and nothing secret does" bash -c "! grep -qF -e '$reader' -e '$controller' '$T/out'"
get /api/snapshot -H "Authorization: Bearer $reader"
check "the streams carry the same host" jqt '.repos[0].streams[0].host == "lap"'
stop
printf 'HERD_BASE=main\n' >"$HERD_CONF"

# --- writes -----------------------------------------------------------------------------------------
routes=(start draft fanout plan plan-resume "done" rm)
# post <route[?query]> <json> [curl args]: POST JSON, with the token $AS (default: the
# controller's; "-" sends none) and the Content-Type $CT (default application/json).
post() {
  local p=$1 body=$2 tok=${AS:-$controller}; shift 2
  [[ $tok == - ]] && tok=""
  code=$(curl -s -o "$T/out" -D "$T/headers" -w '%{http_code}' --max-time 20 -X POST \
    -H "Content-Type: ${CT:-application/json}" ${tok:+-H "Authorization: Bearer $tok"} "$@" \
    --data-binary "$body" "http://127.0.0.1:$port/api/$p")
}
# js k=v ...: a JSON object of string fields, built by jq so nothing needs quoting by hand.
js() {
  local args=() k
  for k in "$@"; do args+=(--arg "${k%%=*}" "${k#*=}"); done
  jq -cn "${args[@]}" '$ARGS.named'
}

echo "writes: who may"
start
allowed=1
for r in "${routes[@]}"; do
  AS=$reader post "$r" "$(js repo="$repo")"
  [[ $code == 403 ]] || { allowed=0; echo "  $r: $code"; }
done
check "the reader token gets 403 on every POST route" test "$allowed" = 1
AS=- post start '{}'
check "no token is 401" test "$code" = 401
post start "$(js repo="$repo")" -H "Host: evil.example"
check "a foreign Host is rejected on POST too" test "$code" = 403
post nope '{}'
check "an unknown POST route is 404" test "$code" = 404
post start "$(js repo="$repo" prompt="$(head -c 70000 /dev/zero | tr '\0' x)")"
check "a body over 64 KB is 413" test "$code" = 413
CT=text/plain post start "$(js repo="$repo")"
check "a body that's not application/json is 415" test "$code" = 415
post start '[1]'
check "a body that's not a JSON object is 400" test "$code" = 400
stop

start --read-only; rc=$?
check "--read-only starts and says so" bash -c "test $rc = 0 && grep -q read-only '$T/log'"
allowed=1
for r in "${routes[@]}"; do
  post "$r" "$(js repo="$repo")"
  [[ $code == 405 || $code == 403 ]] || { allowed=0; echo "  $r: $code"; }
done
check "--read-only turns every POST route off, also for the controller" test "$allowed" = 1
get /api/config -H "Authorization: Bearer $reader"
check "...and /api/config says so" jqt '.read_only == true'
stop

# The write routes against a fake herd: status, show and personas are the real bin/herd; anything
# else logs its argv (one line, args joined by |) and prints what herd would.
cat >"$T/fakeherd" <<EOF
#!/usr/bin/env bash
case \$1 in status|show|personas) exec bash "$herd" "\$@" ;; esac
(IFS='|'; echo "\$*") >>"$T/herd.calls"
out="" dry=""
while ((\$#)); do
  case \$1 in -o) out=\$2; shift 2 ;; -n) dry=1; shift ;; *) shift ;; esac
done
if [[ -n \$out ]]; then
  cat >"$T/draft.stdin"; printf 'feat/d @engineer: Do the thing.\n' >"\$out"; echo "wrote \$out"; exit 0
fi
if [[ -n \$dry ]]; then echo "feat/d  feat-d  engineer  Do the thing...."; exit 0; fi
echo "started feat-d"
EOF
calls() { cat "$T/herd.calls" 2>/dev/null; }
last_call() { tail -1 "$T/herd.calls" 2>/dev/null; }
git init -q -b main "$T/other" && git -C "$T/other" commit -q --allow-empty -m init
fstart() {
  port=$(free_port)
  python3 "$root/serve/herd_serve.py" --port "$port" --state-dir "$state" --web "$root/web" --base main \
    --plugin "$root/plugin/herd-plugin.sh" --repos "$T/other" --agent-arg=--permission-mode --agent-arg=auto \
    --herd bash "$T/fakeherd" >"$T/log" 2>&1 &
  pid=$!
  local i
  for ((i = 0; i < 100; i++)); do
    curl -fs "http://127.0.0.1:$port/healthz" >/dev/null 2>&1 && return 0
    sleep 0.1
  done
  return 1
}
rm -f "$state/serve-audit.jsonl"
check "the server starts with a fake herd" fstart
audit=$state/serve-audit.jsonl

echo "writes: start"
get "/api/personas?repo=$repo" -H "Authorization: Bearer $reader"
check "/api/personas lists herd personas" jqt '[.personas[].name] | index("engineer")'
check "...without their file paths" bash -c "! grep -q '\\.md' '$T/out'"
secret="Fix the SECRET-PROMPT-7f3a thing; run make test."
post start "$(js repo="$repo" branch=feat/new persona=engineer prompt="$secret")"
check "POST /api/start runs herd with the task" bash -c "test $code = 200 && jq -e '.ok == true and (.output | contains(\"started\"))' '$T/out' >/dev/null"
check "...as herd -r <repo> -b <base> -k <kind> -P <persona> <branch> <prompt> -- <agent args>" \
  test "$(last_call)" = "-r|$repo|-b|main|-k|claude|-P|engineer|feat/new|$secret|--|--permission-mode|auto"
rid=$(jq -r .request_id "$T/out")
check "...with a request id, in the body and a header" \
  bash -c "[[ $rid =~ ^[0-9a-f]{16}\$ ]] && grep -qi '^x-request-id: $rid' '$T/headers'"
n=$(calls | wc -l)
post start "$(js repo="$repo" branch=feat/a prompt=x)"
check "a branch that exists is refused (409)" test "$code" = 409
bad_branches=1
for b in "bad branch" "-x" "a..b" "fix @eng" "x:y" "/abs" ""; do
  post start "$(js repo="$repo" branch="$b" prompt=x)"
  [[ $code == 400 ]] || { bad_branches=0; echo "  '$b': $code"; }
done
check "invalid branch names are 400" test "$bad_branches" = 1
post start "$(js repo="$repo" branch=feat/b persona=nobody-at-all prompt=x)"
check "an unknown persona is 400" bash -c "test $code = 400 && jq -e '.error | contains(\"persona\")' '$T/out' >/dev/null"
post start "$(js repo="$T" branch=feat/b prompt=x)"
check "a repo herd serve doesn't know is 404" test "$code" = 404
post start "$(js repo="$repo" branch=feat/b prompt="  ")"
check "an empty prompt is 400" test "$code" = 400
check "...and none of those ran herd" test "$(calls | wc -l)" = "$n"
post start "$(js repo="$T/other" branch=feat/b persona=none prompt=x)"
check "a HERD_SERVE_REPOS repo with no streams yet is allowed, and persona none (bare)" \
  bash -c "test $code = 200 && [[ '$(last_call)' == '-r|$T/other|-b|main|-k|claude|-P|none|feat/b|x|--|'* ]]"

echo "writes: the audit log"
check "every POST leaves one line in serve-audit.jsonl" test "$(wc -l <"$audit")" = 13
check "...each with ts, token_role, route, repo, branch, ok and a request id" \
  bash -c "jq -se 'all(has(\"ts\") and has(\"token_role\") and has(\"route\") and has(\"repo\") and has(\"branch\") and has(\"ok\") and has(\"request_id\"))' '$audit' >/dev/null"
check "...the start's: controller, its repo and branch, ok, the request id" \
  bash -c "head -1 '$audit' | jq -e '.token_role == \"controller\" and .route == \"/api/start\" and .repo == \"$repo\" and .branch == \"feat/new\" and .ok == true and .request_id == \"$rid\"' >/dev/null"
sha=$(printf '%s' "$secret" | sha256sum | cut -d' ' -f1)
check "...the prompt only as its length and sha256" \
  bash -c "head -1 '$audit' | jq -e '.prompt_len == ${#secret} and .prompt_sha256 == \"$sha\"' >/dev/null"
check "the prompt text is in neither the audit log nor the server log" \
  bash -c "! grep -qF SECRET-PROMPT '$audit' '$T/log'"
check "the audit log is mode 0600" test "$(stat -c %a "$audit" 2>/dev/null || stat -f %Lp "$audit")" = 600

echo "writes: draft"
n=$(calls | wc -l)
escapes=1
for o in "../Tasks.herd" "/tmp/Tasks.herd" "sub/Tasks.herd" "Notes.herd" "Tasks.md" ".Tasks.herd" "Tasks.herd/../../x.herd"; do
  post draft "$(js repo="$repo" goal=g output="$o")"
  [[ $code == 400 ]] || { escapes=0; echo "  '$o': $code"; }
done
check "draft's output must be a Tasks*.herd in the repo root" test "$escapes" = 1
ln -s "$T/elsewhere.herd" "$repo/Tasks-link.herd"
post draft "$(js repo="$repo" goal=g output=Tasks-link.herd)"
check "...and not a symlink out of it" test "$code" = 400
check "...and none of those ran herd" test "$(calls | wc -l)" = "$n"
post draft "$(js repo="$repo" goal="Split the GOAL-TEXT-9c work" output=Tasks-x.herd)"
check "POST /api/draft runs herd draft -o <output>, the goal on stdin" \
  bash -c "test $code = 200 && [[ \"\$(sed -n '$((n + 1))p' '$T/herd.calls')\" == 'draft|-r|$repo|-b|main|-o|$repo/Tasks-x.herd|-' ]] && grep -q GOAL-TEXT '$T/draft.stdin'"
check "...and returns the saved file, its dry run and a fan-out hash" \
  jqt '.ok and .file == "Tasks-x.herd" and (.text | contains("feat/d @engineer")) and (.dry_run | contains("feat-d")) and (.hash | length == 64)'
check "...its dry run being herd -n -f <file>" test "$(last_call)" = "-n|-r|$repo|-f|$repo/Tasks-x.herd"
draft_hash=$(jq -r .hash "$T/out")
post draft "$(js repo="$repo" goal=g output=Tasks-x.herd)"
check "a draft over an existing file is 409" test "$code" = 409
check "the goal is not in the audit log" bash -c "! grep -qF GOAL-TEXT '$audit'"

echo "writes: fan out"
n=$(calls | wc -l)
escapes=1
for f in "../x.herd" "$repo/Tasks-x.herd" "sub/x.herd" "Tasks-x.md" "Tasks-link.herd"; do
  post fanout "$(js repo="$repo" file="$f")"
  [[ $code == 400 ]] || { escapes=0; echo "  '$f': $code"; }
done
check "fanout's file must be a *.herd in the repo root" test "$escapes" = 1
post fanout "$(js repo="$repo" file=Tasks-x.herd)"
check "a fan-out with no preview hash is refused (409)" test "$code" = 409
post fanout "$(js repo="$repo" file=Tasks-x.herd hash="$(printf '0%.0s' {1..64})")"
check "...and so is one with a made-up hash" test "$code" = 409
check "...and neither started anything" test "$(calls | wc -l)" = "$n"
post "fanout?dry=1" "$(js repo="$repo" file=Tasks-x.herd)"
check "?dry=1 runs herd -n and returns the batch's hash" \
  bash -c "test $code = 200 && [[ '$(last_call)' == '-n|-r|$repo|-f|$repo/Tasks-x.herd' ]] && jq -e '.hash | length == 64' '$T/out' >/dev/null"
hash=$(jq -r .hash "$T/out")
check "...the same hash the draft gave" test "$hash" = "$draft_hash"
echo "feat/e @engineer: Another thing." >>"$repo/Tasks-x.herd"
post fanout "$(js repo="$repo" file=Tasks-x.herd hash="$hash")"
check "the hash of a preview from before an edit is stale (409)" test "$code" = 409
post "fanout?dry=1" "$(js repo="$repo" file=Tasks-x.herd)"
hash=$(jq -r .hash "$T/out")
post fanout "$(js repo="$repo" file=Tasks-x.herd hash="$hash")"
check "a fresh preview's hash starts the batch: herd -r <repo> -b -k -f <file> -- <agent args>" \
  bash -c "test $code = 200 && [[ '$(last_call)' == '-r|$repo|-b|main|-k|claude|-f|$repo/Tasks-x.herd|--|--permission-mode|auto' ]]"
post fanout "$(js repo="$repo" file=Tasks-x.herd hash="$hash")"
check "...once: the same hash again is refused" test "$code" = 409

echo "writes: plan"
: >"$T/herdr.calls"
post plan "$(js repo="$repo" branch=feat/plan plan_text=$'## Stage 1: one\n\nDo PLAN-TEXT-4d one thing.' verify="make test" persona=engineer)"
check "POST /api/plan writes the plan to .herd/inbox/<branch>.md" \
  bash -c "test $code = 200 && grep -q PLAN-TEXT '$repo/.herd/inbox/feat/plan.md'"
check "...keeps .herd/inbox out of git status" \
  bash -c "grep -qx '/.herd/inbox/' '$repo/.git/info/exclude' && ! git -C '$repo' status --porcelain | grep -q herd/"
check "...and opens the plugin's plan pane in a herdr tab of the repo's workspace, with the form" \
  bash -c "grep -q -- '--entrypoint plan .*--env HERD_REPO=$repo --env HERD_BRANCH=feat/plan --env HERD_PLAN_FILE=$repo/.herd/inbox/feat/plan.md --env HERD_PLAN_VERIFY=make test --env HERD_PLAN_PERSONA=engineer --workspace w1' '$T/herdr.calls'"
check "...not as a child of the server: herd plan never ran here" bash -c "! grep -q '^plan' '$T/herd.calls'"
check "the plan text is not in the audit log, only its length and sha256" \
  bash -c "! grep -qF PLAN-TEXT '$audit' && tail -1 '$audit' | jq -e '.plan_len > 0 and (.plan_sha256 | length == 64)' >/dev/null"
post plan-resume "$(js repo="$repo" branch=feat/a)"
check "plan-resume of a stream with no plan is 409" test "$code" = 409
mkdir -p "$wt/.herd/run"; printf 'stage=1\nstatus=blocked\n' >"$wt/.herd/run/state"; touch "$state/serve.nudge"
: >"$T/herdr.calls"
post plan-resume "$(js repo="$repo" branch=feat/a)"
check "POST /api/plan-resume opens the plugin's plan-resume pane for that branch" \
  bash -c "test $code = 200 && grep -q -- '--entrypoint plan-resume .*--env HERD_BRANCH=feat/a --workspace w1' '$T/herdr.calls'"

echo "writes: done, rm"
post "done" "$(jq -cn --arg r "$repo" '{repo: $r, branches: ["feat/a"]}')"
check "POST /api/done runs herd done -r <repo> -b <base> <branches>" \
  bash -c "test $code = 200 && [[ '$(last_call)' == 'done|-r|$repo|-b|main|feat/a' ]]"
post "done" "$(jq -cn --arg r "$repo" '{repo: $r, branches: ["main"]}')"
check "...only for streams of the snapshot" test "$code" = 404
post rm "$(jq -cn --arg r "$repo" '{repo: $r, branches: ["feat/a"]}')"
check "POST /api/rm without confirm: discard is 400" test "$code" = 400
post rm "$(jq -cn --arg r "$repo" '{repo: $r, branches: ["feat/a"], confirm: "yes"}')"
check "...and so is any other confirm" test "$code" = 400
post rm "$(jq -cn --arg r "$repo" '{repo: $r, branches: ["feat/a"], confirm: "discard"}')"
check "with it, herd rm -r <repo> <branches> runs" \
  bash -c "test $code = 200 && [[ '$(last_call)' == 'rm|-r|$repo|feat/a' ]]"
check "the audit line of a list of branches lists them" \
  bash -c "tail -1 '$audit' | jq -e '.branch == [\"feat/a\"] and .route == \"/api/rm\"' >/dev/null"
stop
rm -rf "$wt/.herd"

echo "listen"
printf 'HERD_BASE=main\nHERD_SERVE_LISTEN=0.0.0.0\n' >"$HERD_CONF"
"$herd" serve --port "$(free_port)" >"$T/log" 2>&1; rc=$?
check "a non-loopback HERD_SERVE_LISTEN alone is refused" bash -c "test $rc != 0 && grep -q 'pass --listen' '$T/log'"
rm "$state/serve-tokens.json"
"$herd" serve --listen 0.0.0.0 --port "$(free_port)" >"$T/log" 2>&1; rc=$?
check "an explicit non-loopback --listen without tokens is refused" bash -c "test $rc != 0 && grep -q 'without tokens' '$T/log'"
check "...and writes no tokens" test ! -e "$state/serve-tokens.json"
"$herd" serve --port x >"$T/log" 2>&1; rc=$?
check "a bad --port is refused" test "$rc" != 0

# --- pair, revoke, install ----------------------------------------------------------------------
echo "pair"
# Fakes for everything that would touch this machine: qrencode, systemctl, launchctl (and uname
# for the macOS case). They only log.
for c in qrencode systemctl launchctl; do
  printf '#!/usr/bin/env bash\necho "%s $*" >>"%s/sys.calls"\n[[ %s != qrencode ]] || echo "QR($*)"\n' "$c" "$T" "$c" >"$T/bin/$c"
  chmod +x "$T/bin/$c"
done
printf 'HERD_BASE=main\n' >"$HERD_CONF"
"$herd" serve pair >"$T/out" 2>&1
controller=$(token controller) reader=$(token reader)
check "pair makes the tokens if there are none" test -n "$controller"
check "...and prints the loopback link with the controller token" grep -qF "http://127.0.0.1:8380/#t=$controller" "$T/out"
check "...says it only works on this computer, and how to reach it from a phone" \
  bash -c "grep -q 'this computer only' '$T/out' && grep -q HERD_SERVE_LISTEN '$T/out'"
check "...with no QR code for a loopback link" bash -c "! grep -q QR '$T/out'"
printf 'HERD_BASE=main\nHERD_SERVE_LISTEN=100.64.1.2\nHERD_SERVE_HOSTS="lap.netbird.cloud, 100.64.1.2"\nHERD_SERVE_PORT=9000\n' >"$HERD_CONF"
"$herd" serve pair >"$T/out" 2>&1
check "a link for the listen address and each HERD_SERVE_HOSTS name, once each" \
  bash -c "test \$(grep -c '^  http://' '$T/out') = 2 && grep -qF 'http://100.64.1.2:9000/#t=$controller' '$T/out' && grep -qF 'http://lap.netbird.cloud:9000/#t=$controller' '$T/out'"
check "...each with a terminal QR code from qrencode -t ansiutf8" grep -qF "QR(-t ansiutf8 http://lap.netbird.cloud:9000/#t=$controller)" "$T/out"
"$herd" serve pair --reader >"$T/out" 2>&1
check "--reader pairs with the reader token instead" \
  bash -c "grep -qF '#t=$reader' '$T/out' && ! grep -qF '$controller' '$T/out'"
printf 'HERD_BASE=main\nHERD_SERVE_LISTEN=0.0.0.0\nHERD_SERVE_HOSTS=lap.netbird.cloud\n' >"$HERD_CONF"
"$herd" serve pair >"$T/out" 2>&1
check "a wildcard listen address gets no link, the names do" \
  bash -c "! grep -q 0.0.0.0 '$T/out' && grep -qF 'http://lap.netbird.cloud:8380/' '$T/out'"

echo "revoke"
printf 'HERD_BASE=main\n' >"$HERD_CONF"
start
get /api/snapshot -H "Authorization: Bearer $reader"
check "the reader token works before" test "$code" = 200
"$herd" serve revoke --reader >"$T/out" 2>&1
check "revoke --reader gives a new reader token and keeps the controller's" \
  bash -c "[[ \$(jq -r .reader '$state/serve-tokens.json') != '$reader' && \$(jq -r .controller '$state/serve-tokens.json') == '$controller' ]]"
check "...in a file still mode 0600" test "$(stat -c %a "$state/serve-tokens.json" 2>/dev/null || stat -f %Lp "$state/serve-tokens.json")" = 600
get /api/snapshot -H "Authorization: Bearer $reader"
check "a running herd serve refuses the old token at once (401)" test "$code" = 401
get /api/snapshot -H "Authorization: Bearer $(token reader)"
check "...and takes the new one" test "$code" = 200
get /api/snapshot -H "Authorization: Bearer $controller"
check "...while the controller keeps working" test "$code" = 200
stop
reader=$(token reader)
"$herd" serve revoke >"$T/out" 2>&1
check "revoke with no flag rotates both" \
  bash -c "[[ \$(jq -r .reader '$state/serve-tokens.json') != '$reader' && \$(jq -r .controller '$state/serve-tokens.json') != '$controller' ]]"
check "...and says to pair again" grep -q 'herd serve pair' "$T/out"
"$herd" serve revoke --bogus >"$T/out" 2>&1; rc=$?
check "an unknown revoke flag is refused" test "$rc" != 0

echo "install"
printf 'HERD_BASE=main\nHERD_SERVE_LISTEN=100.64.1.2\nHERD_SERVE_PORT=9000\nHERD_SERVE_READ_ONLY=1\n' >"$HERD_CONF"
unit=$T/.config/systemd/user/herd-serve.service
: >"$T/sys.calls"
"$herd" serve install >"$T/out" 2>&1; rc=$?
check "install writes a systemd user unit under ~/.config/systemd/user" bash -c "test $rc = 0 && test -f '$unit'"
check "...running herd serve with herd.conf's flags, --listen explicit" \
  grep -qF '"serve" "--listen" "100.64.1.2" "--port" "9000" "--read-only"' "$unit"
check "...restarting on failure, with HERD_CONF and PATH set" \
  bash -c "grep -qx 'Restart=on-failure' '$unit' && grep -qF '\"HERD_CONF=$HERD_CONF\"' '$unit' && grep -q '^Environment=\"PATH=' '$unit' && grep -qx 'WantedBy=default.target' '$unit'"
check "...prints what it wrote" grep -qF "wrote $unit" "$T/out"
check "...and enables it as a user unit, nothing system-wide" \
  bash -c "grep -qx 'systemctl --user daemon-reload' '$T/sys.calls' && grep -qx 'systemctl --user enable --now herd-serve.service' '$T/sys.calls' && ! grep -v -- '--user' '$T/sys.calls' | grep -q systemctl"
"$herd" serve uninstall >"$T/out" 2>&1
check "uninstall disables and removes it" \
  bash -c "test ! -e '$unit' && grep -qx 'systemctl --user disable --now herd-serve.service' '$T/sys.calls'"
"$herd" serve uninstall >"$T/out" 2>&1; rc=$?
check "...and says so when there is none" bash -c "test $rc = 0 && grep -q 'no herd serve unit' '$T/out'"
printf '#!/usr/bin/env bash\necho Darwin\n' >"$T/bin/uname"; chmod +x "$T/bin/uname"
plist=$T/Library/LaunchAgents/lordmuffin.herd-serve.plist
: >"$T/sys.calls"
"$herd" serve install >"$T/out" 2>&1; rc=$?
check "on macOS install writes a launchd agent plist instead" bash -c "test $rc = 0 && test -f '$plist'"
check "...a valid plist with the same argv, KeepAlive on failure" \
  python3 -c "
import plistlib, sys
p = plistlib.load(open(sys.argv[1], 'rb'))
a = p['ProgramArguments']
assert p['Label'] == 'lordmuffin.herd-serve' and a[2:] == ['serve', '--listen', '100.64.1.2', '--port', '9000', '--read-only'], a
assert p['KeepAlive'] == {'SuccessfulExit': False} and p['RunAtLoad'] and p['EnvironmentVariables']['HERD_CONF'] == sys.argv[2]
" "$plist" "$HERD_CONF"
check "...loaded into the user's own launchd domain" grep -qx "launchctl bootstrap gui/$(id -u) $plist" "$T/sys.calls"
"$herd" serve uninstall >"$T/out" 2>&1
check "...and uninstall boots it out and removes it" \
  bash -c "test ! -e '$plist' && grep -qx 'launchctl bootout gui/$(id -u) $plist' '$T/sys.calls'"
rm -f "$T/bin/uname"

rm -rf "$T"
echo
echo "$pass passed, $fail failed"
((fail == 0))
