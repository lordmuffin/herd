#!/usr/bin/env bash
# Tests for the herdr plugin: herdr-plugin.toml, and plugin/herd-plugin.sh's actions, panes and
# event hook. herdr is faked on PATH (it logs every call and answers from JSON files), panes get
# their keystrokes on stdin, and claude is faked for draft.
#
#   bash tests/plugin.sh        (make test runs it)
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(cd "$here/.." && pwd)
plugin=$root/plugin/herd-plugin.sh
manifest=$root/herdr-plugin.toml
# Run inside a herdr pane, these would reach the real herdr and its workspaces.
unset HERDR_BIN_PATH HERDR_SOCKET_PATH HERDR_PLUGIN_ID HERDR_PLUGIN_CONTEXT_JSON HERDR_PLUGIN_EVENT_JSON \
  HERDR_WORKSPACE_ID HERDR_TAB_ID HERDR_PANE_ID HERDR_PLUGIN_CONFIG_DIR HERDR_PLUGIN_STATE_DIR HERD_REPO \
  XDG_STATE_HOME HERD_STATE_DIR
export HERD_NO_FZF=1 EDITOR=true VISUAL=true

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; [[ -z ${2:-} ]] || sed 's/^/       /' <<<"$2"; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name" "$(cat "$T/out" "$T/calls" 2>/dev/null)"; fi; }
called() { grep -qF -- "$1" "$T/calls" 2>/dev/null; }
not_called() { ! called "$1"; }
ncalls() { grep -cF -- "$1" "$T/calls" 2>/dev/null || true; }

# A repo with a Tasks.herd and one herd stream (a real worktree at ~/git/wt/proj/feat-a), and a
# herdr that answers worktree list / agent list from $T/*.json.
setup() {
  T=$(mktemp -d)
  export HOME=$T XDG_DATA_HOME=$T/xdg HERDR_PLUGIN_CONFIG_DIR=$T/conf HERDR_PLUGIN_STATE_DIR=$T/state
  export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
  repo=$T/proj wt=$T/git/wt/proj/feat-a
  git init -q -b main "$repo" && git -C "$repo" commit -q --allow-empty -m init
  printf 'feat/n @none: do n\nfeat/m: do m\n' >"$repo/Tasks.herd"
  printf '## Stage 1: One\nverify: true\n\nDo one.\n' >"$repo/PLAN.md"
  git -C "$repo" worktree add -q -b feat/a "$wt"
  mkdir -p "$T/bin" "$T/conf"
  printf 'HERD_BASE=main\nHERD_AGENT_ARGS="--model sonnet"\n' >"$T/conf/herd.conf"
  cat >"$T/worktrees.json" <<EOF
{"result":{"worktrees":[
  {"path":"$repo","branch":"main","is_linked_worktree":false,"open_workspace_id":"w1"},
  {"path":"$wt","branch":"feat/a","is_linked_worktree":true,"open_workspace_id":"w5"},
  {"path":"$T/elsewhere","branch":"other","is_linked_worktree":true,"open_workspace_id":null}]}}
EOF
  agents feat-a w5:p1 "$wt" working
  cat >"$T/bin/herdr" <<EOF
#!/usr/bin/env bash
echo "\$*" >>"$T/calls"
case "\$1 \$2" in
  "worktree create") echo '{"result":{"root_pane":{"pane_id":"w9:p1"}}}' ;;
  "worktree list") cat "$T/worktrees.json" ;;
  "agent list") cat "$T/agents.json" ;;
  "workspace list") echo '{"result":{"workspaces":[]}}' ;;
  "pane list") echo '{"result":{"panes":[]}}' ;;
  "pane get") grep -qx "\$3" "$T/live-panes" 2>/dev/null || exit 1 ;;
  "agent read") printf 'Reading src/x.rs\n\n────────────\nEditing src/x.rs: 3 lines\n' ;;
  "workspace focus") [[ \$3 != w404 ]] || exit 1 ;;
esac
EOF
  # draft's dispatcher: answers with a valid task file whatever it is asked.
  cat >"$T/bin/claude" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '# the x part\nfeat/x @engineer: Do x and open a PR.\n'
EOF
  chmod +x "$T/bin/herdr" "$T/bin/claude"
  export PATH=$T/bin:$ORIG_PATH
}
ORIG_PATH=$PATH

# agents name pane cwd status [name pane cwd status ...]: what `herdr agent list` returns.
agents() {
  local a=()
  while (($# >= 4)); do
    a+=("$(printf '{"name":"%s","pane_id":"%s","cwd":"%s","agent_status":"%s"}' "$1" "$2" "$3" "$4")"); shift 4
  done
  (IFS=,; printf '{"result":{"agents":[%s]}}\n' "${a[*]}") >"$T/agents.json"
}

act() { (bash "$plugin" action "$1") >"$T/out" 2>&1; rc=$?; }
# pane <id> <stdin>: a pane in $repo, as an action opens it.
pane() { (cd "$root" && HERD_REPO=$repo bash "$plugin" pane "$1" <<<"$2") >"$T/out" 2>&1; rc=$?; }
event() { # pane status
  (HERDR_PLUGIN_EVENT_JSON=$(printf '{"event":"pane_agent_status_changed","data":{"pane_id":"%s","workspace_id":"w5","agent_status":"%s"}}' "$1" "$2") \
    bash "$plugin" event) >"$T/out" 2>&1; rc=$?
}
out_has() { grep -qF -- "$1" "$T/out"; }

# --- the manifest ------------------------------------------------------------------------------
echo "herdr-plugin.toml"
mf_actions=$(awk '/^\[\[/ { s = $0 } s == "[[actions]]" && /^id = / { gsub(/"/, "", $3); print $3 }' "$manifest")
mf_panes=$(awk '/^\[\[/ { s = $0 } s == "[[panes]]" && /^id = / { gsub(/"/, "", $3); print $3 }' "$manifest")
check "declares actions" test -n "$mf_actions"
check "every action but version has a pane of the same id" \
  test "$(grep -vx version <<<"$mf_actions" | sort)" = "$(sort <<<"$mf_panes")"
if python3 -c 'import tomllib' 2>/dev/null; then
  if msg=$(python3 -I - "$manifest" "$root" <<'EOF' 2>&1
import os, re, sys, tomllib
path, root = sys.argv[1], sys.argv[2]
m = tomllib.load(open(path, "rb"))
errs = []
for k in ("id", "name", "version", "min_herdr_version"):
    if not str(m.get(k, "")).strip():
        errs.append(f"missing {k}")
if not re.fullmatch(r"[A-Za-z0-9.:_-]{1,120}", m.get("id", "")):
    errs.append("bad plugin id")
if not re.fullmatch(r"\d+\.\d+\.\d+", m.get("min_herdr_version", "")):
    errs.append("min_herdr_version is not x.y.z")
version = open(os.path.join(root, "VERSION")).readline().strip()
if m.get("version") != version:
    errs.append(f"version {m.get('version')} != VERSION {version}")
if sorted(m.get("platforms", [])) != ["linux", "macos"]:
    errs.append("platforms must be linux and macos")
events = {"workspace.created", "workspace.updated", "workspace.closed", "workspace.renamed",
          "workspace.moved", "workspace.reordered", "workspace.focused", "worktree.created",
          "worktree.opened", "worktree.removed", "tab.created", "tab.closed", "tab.renamed",
          "tab.moved", "tab.focused", "pane.created", "pane.closed", "pane.focused", "pane.moved",
          "pane.exited", "pane.agent_detected", "pane.agent_status_changed"}
for kind in ("actions", "panes", "events"):
    seen = set()
    for item in m.get(kind, []):
        cmd = item.get("command", [])
        if not cmd or any(not a for a in cmd):
            errs.append(f"{kind}: empty command")
        elif len(cmd) > 1 and not os.path.isfile(os.path.join(root, cmd[1])):
            errs.append(f"{kind}: {cmd[1]} does not exist")
        if kind == "events":
            if item.get("on") not in events:
                errs.append(f"unknown event {item.get('on')}")
            continue
        i = item.get("id", "")
        if not re.fullmatch(r"[A-Za-z0-9:_-]{1,120}", i):
            errs.append(f"{kind}: bad id {i!r}")
        if i in seen:
            errs.append(f"{kind}: duplicate id {i}")
        seen.add(i)
        if not item.get("title", "").strip():
            errs.append(f"{kind}: {i} has no title")
        if kind == "panes" and item.get("placement", "overlay") not in ("overlay", "popup", "split", "tab", "zoomed"):
            errs.append(f"pane {i}: bad placement")
print("\n".join(errs))
sys.exit(1 if errs else 0)
EOF
  ); then ok "parses and passes herdr's manifest rules"; else bad "parses and passes herdr's manifest rules" "$msg"; fi
else
  echo "  skip TOML checks (no python3 with tomllib)"
fi

# --- actions -----------------------------------------------------------------------------------
echo "actions"
setup
for id in $(grep -vx version <<<"$mf_actions"); do
  : >"$T/calls"
  HERDR_PLUGIN_CONTEXT_JSON="{\"focused_pane_cwd\":\"$wt\"}" act "$id"
  check "$id opens its pane, in the main checkout of the focused worktree" \
    called "plugin pane open --plugin lordmuffin.herd --entrypoint $id --env PATH=$T/bin:"
  check "...with HERD_REPO set to it" called "--focus --env HERD_REPO=$repo"
done
: >"$T/calls"; HERDR_PLUGIN_CONTEXT_JSON='{"focused_pane_cwd":"/"}' act status
check "outside a repo the pane gets no HERD_REPO" not_called "HERD_REPO="
check "...but still opens" called "--entrypoint status"
act bogus
check "an unknown action fails" test "$rc" = 2
: >"$T/calls"; act version
check "version notifies with the version" called "notification show herd $(head -n1 "$root/VERSION")"
make -s -C "$root" install DESTDIR="$T/pkg" PREFIX=/usr >/dev/null
: >"$T/calls"; (bash "$T/pkg/usr/share/herd/plugin/herd-plugin.sh" action version) >"$T/out" 2>&1
check "make install's copy (share/herd) finds herd in bin" called "notification show herd $(head -n1 "$root/VERSION") --body plugin lordmuffin.herd at $T/pkg/usr/share/herd"

# --- panes -------------------------------------------------------------------------------------
echo "pane fanout"
setup; pane fanout $'\ny\n'
check "exits 0" test "$rc" = 0
check "shows the dry run first" out_has "feat-n"
check "starts one worktree per task" test "$(ncalls 'worktree create')" = 2
check "agents get HERD_AGENT_ARGS" called "agent start feat-m --kind claude --pane w9:p1 --timeout 90000 -- --model sonnet"
check "remembers the batch for the event hook" grep -qx feat-n "$T"/state/batches/*
setup; pane fanout $'\nn\n'
check "a no starts nothing" not_called "worktree create"
setup; rm "$repo/Tasks.herd"; pane fanout ""
check "no task file says how to make one" out_has "no task file in $repo"

echo "pane status"
setup; mkdir -p "$wt/.herd/run"
printf 'stage=2\nstatus=running\n' >"$wt/.herd/run/state"
printf '## Stage 1: a\n## Stage 2: b\n## Stage 3: c\n' >"$wt/.herd/run/stages.md"
pane status q
check "lists the stream with its agent status" grep -qE 'feat/a +feat-a +working' "$T/out"
check "shows where its plan is" out_has "stage 2/3 running"
check "leaves out worktrees herd did not make" bash -c "! grep -q other '$T/out'"
check "herd status -j gives JSON" bash -c "cd '$repo' && PATH='$PATH' '$root/bin/herd' status -j | jq -e 'select(.branch == \"feat/a\") | .plan == \"stage 2/3 running\"' >/dev/null"

echo "pane plan / plan-resume"
setup; pane plan $'feat/p\n1\n\n\ny\n'
check "runs herd plan with the picked plan and the engineer default" out_has "feat/p (feat-p), persona engineer, 1 stage(s)"
check "notifies when the plan run ends" called "notification show herd: plan feat/p ended"
setup; pane plan $'not a branch\n'
check "refuses a bad branch name" out_has "not a valid branch name"
setup
(cd "$root" && HERD_REPO=$repo HERD_BRANCH=feat/q HERD_PLAN_FILE=$repo/PLAN.md HERD_PLAN_PERSONA=engineer \
  bash "$plugin" pane plan <<<"") >"$T/out" 2>&1
check "a filled-in plan form (from herd serve) runs herd plan without asking" \
  bash -c "grep -qF 'branch feat/q, plan $repo/PLAN.md, persona engineer' '$T/out' && ! grep -q 'branch (e.g.' '$T/out'"
check "...for real: the plan's worktree and agent start" \
  bash -c "grep -qF 'worktree create --cwd $repo --branch feat/q' '$T/calls' && grep -qF 'agent start feat-q' '$T/calls'"
: >"$T/calls"
(HERD_REPO=$repo HERD_BRANCH=feat/q HERD_PLAN_FILE=$repo/PLAN.md HERD_PLAN_VERIFY="make test" bash "$plugin" action plan) >"$T/out" 2>&1
check "the plan action hands a filled-in form to its pane, in the repo's workspace" \
  called "--env HERD_REPO=$repo --env HERD_BRANCH=feat/q --env HERD_PLAN_FILE=$repo/PLAN.md --env HERD_PLAN_VERIFY=make test --workspace w1"
setup; pane plan-resume ""
check "no plan state, nothing to resume" out_has "no stopped plans"
mkdir -p "$wt/.herd/run"; printf 'stage=1\nstatus=blocked\n' >"$wt/.herd/run/state"
pane plan-resume ""
check "lists a stopped plan" out_has "stage 1/? blocked"

echo "pane done / rm"
setup; pane "done" $'1\n'
check "runs herd done on the picked stream" out_has "can't check feat/a's PR"
setup; pane rm $'1\nnope\n'
check "rm wants the word discard" out_has "nothing removed"
check "...and removes nothing without it" not_called "worktree remove"
setup; pane rm $'a\ndiscard\n'
check "rm discard removes the stream" called "worktree remove --workspace w5 --force"

echo "pane draft"
setup; pane draft $'Add x\n\nn\n'
f=$(ls "$repo"/Tasks-*.herd 2>/dev/null | head -1)
check "Tasks.herd exists, so it writes a dated file" test -n "$f"
check "the file has the dispatcher's task" grep -qx 'feat/x @engineer: Do x and open a PR.' "${f:-/dev/null}"
setup; rm "$repo/Tasks.herd"; pane draft $'Add x\n\nn\n'
check "with no Tasks.herd it writes Tasks.herd" test -f "$repo/Tasks.herd"

echo "pane serve"
if command -v python3 >/dev/null; then
  setup
  port=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
  printf 'HERD_BASE=main\nHERD_SERVE_PORT=%s\n' "$port" >"$T/conf/herd.conf"
  # A closing tab hangs up the pane's whole process group; setsid gives this run one of its own.
  (cd "$root" && HERD_REPO=$repo HERD_STATE_DIR=$T/st exec setsid bash "$plugin" pane serve </dev/null) >"$T/out" 2>&1 &
  spid=$!
  for ((i = 0; i < 50; i++)); do grep -q 'listening on' "$T/out" 2>/dev/null && break; sleep 0.1; done
  kill -HUP -- "-$spid" 2>/dev/null; wait "$spid" 2>/dev/null; sleep 0.3
  check "shows the pairing link first, with the controller token" \
    bash -c "grep -qF 'http://127.0.0.1:$port/#t='\"\$(jq -r .controller '$T/st/serve-tokens.json')\" '$T/out'"
  check "...then runs herd serve in the foreground" bash -c "grep -qF 'listening on http://127.0.0.1:$port/' '$T/out'"
  check "...until the tab goes (SIGHUP)" bash -c "! pgrep -f '[h]erd_serve.py.*$T/st' >/dev/null"
else
  echo "  skip: no python3"
fi

echo "pane personas / settings / menu"
setup; pane personas ""
check "personas lists the shipped ones" out_has "engineer"
setup; pane settings ""
check "settings keeps an existing herd.conf" grep -qx 'HERD_BASE=main' "$T/conf/herd.conf"
rm "$T/conf/herd.conf"; pane settings ""
check "settings creates herd.conf from the template" grep -q '^#HERD_NOTIFY=batch' "$T/conf/herd.conf"
setup; pane menu $'6\nq'
check "the menu runs status inline" out_has "herd status  $repo"
: >"$T/calls"; pane menu $'4\n'
check "the menu sends a plan to a tab of its own" called "--entrypoint plan "

# --- the dashboard -----------------------------------------------------------------------------
echo "dashboard"
setup
: >"$T/calls"; HERDR_PLUGIN_CONTEXT_JSON="{\"focused_pane_cwd\":\"$wt\"}" act dashboard
check "opens as a tab of the repo's own workspace" called "--entrypoint dashboard --env PATH="
check "...in the main checkout's workspace (w1)" called "--env HERD_REPO=$repo --workspace w1"
mkdir -p "$T/state/dashboards"; echo w1:p7 >"$T/state/dashboards/$(printf '%s' "$repo" | tr -c 'A-Za-z0-9._-' '_')"
: >"$T/calls"; HERDR_PLUGIN_CONTEXT_JSON="{\"focused_pane_cwd\":\"$repo\"}" act dashboard
check "a stale record (pane gone) opens a new one" called "--entrypoint dashboard"
echo w1:p7 >"$T/live-panes"
echo w1:p7 >"$T/state/dashboards/$(printf '%s' "$repo" | tr -c 'A-Za-z0-9._-' '_')"
: >"$T/calls"; HERDR_PLUGIN_CONTEXT_JSON="{\"focused_pane_cwd\":\"$repo\"}" act dashboard
check "an open one is focused instead" called "plugin pane focus w1:p7"
check "...and no second one opens" not_called "--entrypoint dashboard"

setup
mkdir -p "$wt/.herd/run"
printf 'stage=2\nstatus=running\n' >"$wt/.herd/run/state"
printf '## Stage 1: Parse\n## Stage 2: Writer\n## Stage 3: Docs\n' >"$wt/.herd/run/stages.md"
printf '## Stage 1\nParser done, tests pass.\n' >"$wt/.herd/run/PROGRESS.md"
git -C "$wt" commit -q --allow-empty -m "parse the input"
wtb=$T/git/wt/proj/feat-b; git -C "$repo" worktree add -q -b feat/b "$wtb"
jq --arg p "$wtb" '.result.worktrees += [{path: $p, branch: "feat/b", is_linked_worktree: true, open_workspace_id: "w6"}]' \
  "$T/worktrees.json" >"$T/w.json" && mv "$T/w.json" "$T/worktrees.json"
agents feat-a w5:p1 "$wt" working feat-b w6:p1 "$wtb" blocked
pane dashboard q
check "exits 0 on q" test "$rc" = 0
check "the header counts the streams by status" out_has "2 stream(s): 1 blocked · 1 working"
check "lists each stream with its status" grep -qE '^> feat/a +working +stage 2/3 running +w5' "$T/out"
check "...and the other one" grep -qE '^  feat/b +blocked' "$T/out"
check "the plan timeline marks done, current and to come" \
  bash -c "grep -q '✓ 1 Parse' '$T/out' && grep -q '▶ 2 Writer' '$T/out' && grep -q '· 3 Docs' '$T/out'"
check "shows commits ahead of the base" out_has "1 commit(s) ahead of main"
check "shows the progress log" out_has "Parser done, tests pass."
check "shows the agent's screen, without blank or rule lines" \
  bash -c "grep -q 'Editing src/x.rs: 3 lines' '$T/out' && ! grep -q '────' '$T/out'"
check "removes its marker when it closes" bash -c "! ls '$T'/state/dashboards/.mark.* 2>/dev/null"

pane dashboard $'j\n'
check "j selects the next stream" grep -qE '^> feat/b' "$T/out"
check "enter goes to its workspace" called "workspace focus w6"
setup; : >"$T/calls"; pane dashboard o
check "o goes to the stream's workspace" called "workspace focus w5"
check "...and says so" out_has "went to workspace w5 (feat/a)"
setup; agents; jq '.result.worktrees[1].open_workspace_id = "w404"' "$T/worktrees.json" >"$T/w.json" && mv "$T/w.json" "$T/worktrees.json"
: >"$T/calls"; pane dashboard o
check "a workspace that's gone and no agent: reopen the worktree" called "worktree open --cwd $repo --path $wt --focus"

setup; pane dashboard $'xnope\n '
check "x wants the word discard" out_has "nothing removed"
check "...and removes nothing without it" not_called "worktree remove"
setup; pane dashboard $'xdiscard\n '
check "x discard removes the selected stream" called "worktree remove --workspace w5 --force"
setup; agents feat-a w5:p1 "$wt" idle; pane dashboard $'dy\n '
check "d runs herd done on the selected stream" out_has "can't check feat/a's PR"

setup; pane dashboard r
check "r with no plan says so" out_has "feat/a has no stopped plan"
mkdir -p "$wt/.herd/run"; printf 'stage=1\nstatus=blocked\n' >"$wt/.herd/run/state"
: >"$T/calls"; pane dashboard r
check "r resumes a stopped plan in a tab of its own" called "--entrypoint plan-resume"
check "...for the selected stream" called "--env HERD_BRANCH=feat/a"
printf 'stage=1\nstatus=complete\n' >"$wt/.herd/run/state"
(cd "$root" && HERD_REPO=$repo HERD_BRANCH=feat/a bash "$plugin" pane plan-resume <<<"") >"$T/out" 2>&1
check "plan-resume with HERD_BRANCH runs herd plan -R on it without asking" \
  bash -c "grep -q 'plan on feat/a is already complete' '$T/out' && ! grep -q 'plan to resume' '$T/out'"

setup; pane dashboard $'f\ny\n '
check "f runs the fan-out form inline" test "$(ncalls 'worktree create')" = 2
setup; : >"$T/calls"; pane dashboard p
check "p opens the plan form in a tab" called "--entrypoint plan "
setup; echo hi >"$wt/hello.txt"; git -C "$wt" add hello.txt; git -C "$wt" commit -q -m "say hello"
pane dashboard v
check "v shows the branch's commits and diff against the base" \
  bash -c "grep -q 'say hello' '$T/out' && grep -q '^+hi' '$T/out'"

setup; rm -rf "$wt"; git -C "$repo" worktree prune
jq '.result.worktrees |= map(select(.branch != "feat/a"))' "$T/worktrees.json" >"$T/w.json" && mv "$T/w.json" "$T/worktrees.json"
pane dashboard q
check "with no streams it says how to start some" out_has "no herd streams in this repo yet"
(cd "$root" && bash "$plugin" pane dashboard <<<"") >"$T/out" 2>&1
check "outside a repo it says to focus one" out_has "focus a pane inside a git repo"

# On a real terminal: alternate screen in and out, colours, and the terminal's own size.
if script --version 2>/dev/null | grep -q util-linux; then
  setup
  { sleep 1; printf j; sleep 0.5; printf q; } |
    HERD_REPO=$repo script -qfec "cd '$root' && stty rows 30 cols 90 && bash '$plugin' pane dashboard" /dev/null >"$T/out" 2>&1
  check "on a terminal it uses the alternate screen and leaves it" \
    bash -c "grep -qF \$'\e[?1049h' '$T/out' && grep -qF \$'\e[?1049l' '$T/out'"
  check "...highlights the selected stream" bash -c "grep -qF \$'\e[7m> feat/a' '$T/out'"
  check "...cuts the rule to the terminal's width" grep -qE -- '-{90}' "$T/out"
  check "...and restores the terminal on q" bash -c "tail -c 20 '$T/out' | grep -qF \$'\e[?25h'"
else
  echo "  skip terminal checks (no util-linux script)"
fi

echo "dashboard refresh"
setup; mkdir -p "$T/state"
(HERDR_PLUGIN_EVENT=worktree.created HERDR_PLUGIN_EVENT_JSON='{"event":"worktree_created"}' bash "$plugin" event) >"$T/out" 2>&1
check "a worktree event touches the dashboards' tick" test -f "$T/state/tick"
check "...and does nothing else" test ! -s "$T/calls"
rm -f "$T/state/tick"; event w5:p1 idle
check "an agent status change of a herd stream touches it too" test -f "$T/state/tick"
# herd serve's nudge is in herd's own state dir, and only once herd serve has made that dir.
check "...but makes no herd serve state dir" test ! -e "$T/.local/state/herd"
mkdir -p "$T/.local/state/herd"; event w5:p1 working
check "with herd serve's state dir, a status change touches serve.nudge" test -f "$T/.local/state/herd/serve.nudge"
rm -f "$T/.local/state/herd/serve.nudge"
(HERDR_PLUGIN_EVENT=worktree.removed bash "$plugin" event) >"$T/out" 2>&1
check "...and so does a worktree event" test -f "$T/.local/state/herd/serve.nudge"
# The loop reloads when the tick is newer than its last load: a pane reading slowly from a pipe
# sees the hook fire between two keys.
{ sleep 1.2; HERDR_PLUGIN_EVENT=worktree.removed bash "$plugin" event >/dev/null 2>&1; sleep 1.5; echo q; } |
  (cd "$root" && HERD_REPO=$repo HERD_DASH_POLL=600 bash "$plugin" pane dashboard) >"$T/out" 2>&1
check "an open dashboard redraws on the tick" test "$(grep -c -- '-- end of frame' "$T/out")" -ge 2

# --- the event hook ----------------------------------------------------------------------------
echo "event hook"
setup
mkdir -p "$T/state/batches"; printf '# %s\nfeat-a\nfeat-b\n' "$repo" >"$T/state/batches/1-1"
wtb=$T/git/wt/proj/feat-b; git -C "$repo" worktree add -q -b feat/b "$wtb"
agents feat-a w5:p1 "$wt" idle feat-b w6:p1 "$wtb" working
event w5:p1 idle
check "reports the branch as the \$herd sidebar token" called "pane report-metadata w5:p1 --source herd --token herd=feat/a"
check "no batch notification while one agent still works" not_called "notification show"
agents feat-a w5:p1 "$wt" idle feat-b w6:p1 "$wtb" idle
event w6:p1 idle
check "notifies once the whole batch has finished" called "notification show herd: batch finished (2 agent(s))"
check "...and forgets the batch" bash -c "! ls '$T'/state/batches/* 2>/dev/null"
: >"$T/calls"; event w6:p1 idle
check "...so it notifies only once" not_called "notification show"
check "batch mode stays quiet about single agents" not_called "finished --body"

echo "event hook, HERD_NOTIFY=all"
setup; echo HERD_NOTIFY=all >>"$T/conf/herd.conf"
event w5:p1 working; agents feat-a w5:p1 "$wt" blocked; event w5:p1 blocked
check "an agent that needs input notifies" called "notification show herd: feat-a needs input"
agents feat-a w5:p1 "$wt" idle; : >"$T/calls"; event w5:p1 idle
check "blocked -> idle is not a finish" not_called "feat-a finished"
event w5:p1 working; event w5:p1 idle
check "working -> idle is" called "notification show herd: feat-a finished"
mkdir -p "$wt/.herd/run"; printf 'stage=1\nstatus=running\n' >"$wt/.herd/run/state"
printf '## Stage 1: a\n## Stage 2: b\n' >"$wt/.herd/run/stages.md"
: >"$T/calls"; event w5:p1 working; event w5:p1 idle
check "a plan's agent idling between stages is not a finish" not_called "feat-a finished"
check "a plan reports its stage as the token" called "--token herd=stage 1/2 running"

echo "event hook, other panes"
setup; agents shell w2:p1 "$T/proj" idle
: >"$T/calls"; event w2:p1 idle
check "ignores agents outside herd's worktrees" test "$(grep -vc '^agent list' "$T/calls")" = 0
echo HERD_NOTIFY=off >>"$T/conf/herd.conf"; echo HERD_SIDEBAR=0 >>"$T/conf/herd.conf"
agents feat-a w5:p1 "$wt" blocked; : >"$T/calls"; event w5:p1 blocked
check "HERD_NOTIFY=off and HERD_SIDEBAR=0 keep it silent" test "$(grep -vc '^agent list' "$T/calls")" = 0

echo
echo "$pass passed, $fail failed"
((fail == 0))
