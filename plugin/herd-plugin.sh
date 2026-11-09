#!/usr/bin/env bash
# herd as a herdr plugin. herdr-plugin.toml points every action, pane and event hook here:
#
#   herd-plugin.sh action <id>   [[actions]]: opens the pane of the same id (version only notifies)
#   herd-plugin.sh pane <id>     [[panes]]: the interactive half, in a herdr-owned terminal pane
#   herd-plugin.sh event         [[events]]: pane.agent_status_changed -> sidebar token, notifications
#
# The work itself is bin/herd from the same checkout, so herd needn't be on PATH. Actions run with
# no terminal and the plugin root as cwd, so the repo comes from the focused pane (via
# HERDR_PLUGIN_CONTEXT_JSON) and is handed to the pane as HERD_REPO.

# macOS starts plugin commands with /bin/bash 3.2 unless Homebrew's bash is first on PATH.
if ((BASH_VERSINFO[0] < 4)); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash /home/linuxbrew/.linuxbrew/bin/bash; do
    [[ -x $b ]] && exec "$b" "$0" "$@"
  done
  echo "herd: needs bash 4 or newer (brew install bash)" >&2
  exit 1
fi

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname "$here")
# A checkout or GitHub install has bin/herd next to plugin/; make install puts the plugin in
# <prefix>/share/herd and herd in <prefix>/bin.
herd=$root/bin/herd
[[ -f $herd ]] || herd=$root/../../bin/herd
plugin_id=${HERDR_PLUGIN_ID:-lordmuffin.herd}
# shellcheck source=plugin/dashboard.sh
source "$here/dashboard.sh"

# bin/herd calls plain `herdr`: make that the herdr running this plugin. The server's PATH can be
# thin (a desktop launcher, launchd), so add the usual homes of claude, gh and fj too.
[[ -n ${HERDR_BIN_PATH:-} ]] && PATH="$(dirname "$HERDR_BIN_PATH"):$PATH"
PATH="$PATH:$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:/home/linuxbrew/.linuxbrew/bin"
export PATH

conf_dir=${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herd/plugin}
state_dir=${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herd/plugin}
conf=$conf_dir/herd.conf

# --- settings -----------------------------------------------------------------------------------

HERD_KIND=claude HERD_BASE=origin/main HERD_PERSONA="" HERD_AGENT_ARGS="" HERD_DRAFT_ARGS=""
HERD_NOTIFY=batch HERD_SIDEBAR=1

conf_template() {
  cat <<'EOF'
# herd plugin settings, read at the start of every herd action. Shell syntax.

# Agent kind for herdr agent start (claude, codex, ...).
#HERD_KIND=claude

# Base ref for new worktrees (fetched first when it is origin/...).
#HERD_BASE=origin/main

# Persona for task lines that name none (empty: run them bare). herd: Personas lists them.
#HERD_PERSONA=

# Extra args for every agent herd starts, like `herd -- <args>`. A plan only runs unattended if
# its agent doesn't stop for permission prompts, e.g.:
#HERD_AGENT_ARGS="--permission-mode auto"

# Extra args for the headless claude that herd: Draft runs.
#HERD_DRAFT_ARGS="--model opus"

# Notifications for herd's streams: batch (when every agent of a fan-out has finished, and when a
# plan ends), all (also each agent that finishes or needs input), or off. herdr's own toasts for
# agents in other tabs are separate (ui.toast in herdr's config).
#HERD_NOTIFY=batch

# 1: report a $herd token on herd's agent panes (branch, or plan stage) for the sidebar.
#HERD_SIDEBAR=1

# Seconds between the dashboard's reloads when no event nudges it sooner.
#HERD_DASH_POLL=5
EOF
}

load_conf() {
  # shellcheck source=/dev/null
  [[ -f $conf ]] && source "$conf"
  read -ra agent_args <<<"$HERD_AGENT_ARGS"
  read -ra draft_args <<<"$HERD_DRAFT_ARGS"
}

run_herd() { "$BASH" "$herd" "$@"; }

# --- the repo -------------------------------------------------------------------------------------

# The main checkout of the repo that dir $1 is in, also when $1 is inside one of its worktrees.
main_checkout() {
  local common
  common=$(git -C "$1" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  if [[ $(basename "$common") == .git ]]; then dirname "$common"
  else git -C "$1" rev-parse --show-toplevel 2>/dev/null; fi
}

# HERD_REPO if the action set it, else the repo of the focused pane, its worktree or workspace.
resolve_repo() {
  local c
  [[ -n ${HERD_REPO:-} ]] && { echo "$HERD_REPO"; return; }
  [[ -n ${HERDR_PLUGIN_CONTEXT_JSON:-} ]] || return 1
  while IFS= read -r c; do
    [[ -n $c && -d $c ]] && main_checkout "$c" && return
  done < <(jq -r '.focused_pane_cwd, .worktree.repo_root, .workspace_cwd | values' \
             <<<"$HERDR_PLUGIN_CONTEXT_JSON" 2>/dev/null)
  return 1
}

# --- actions --------------------------------------------------------------------------------------

notify() { # title body sound
  herdr notification show "$1" --body "$2" --sound "${3:-none}" >/dev/null 2>&1 || true
}

open_pane() { # entrypoint repo [KEY=VALUE | --herdr-flag value ...]
  local args=(plugin pane open --plugin "$plugin_id" --entrypoint "$1" --env "PATH=$PATH" --focus)
  [[ -z ${2:-} ]] || args+=(--env "HERD_REPO=$2")
  shift 2 || shift $#
  while (($#)); do
    case $1 in --*) args+=("$1" "$2"); shift 2 ;; *) args+=(--env "$1"); shift ;; esac
  done
  herdr "${args[@]}" >/dev/null
}

# The workspace that has the repo's main checkout open, if any.
repo_workspace() {
  herdr worktree list --cwd "$1" 2>/dev/null |
    jq -r '[.result.worktrees[] | select(.is_linked_worktree | not) | .open_workspace_id // empty][0] // empty'
}

action() {
  load_conf
  case $1 in
    version)
      local v; v=$(run_herd --version)
      echo "$v"; notify "$v" "plugin $plugin_id at $root"; return ;;
    menu | dashboard | fanout | draft | plan | plan-resume | status | "done" | rm | personas | settings) ;;
    *) echo "herd: unknown action '$1'" >&2; return 2 ;;
  esac
  local repo; repo=$(resolve_repo) || repo=""
  if [[ $1 == dashboard && -n $repo ]]; then open_dashboard "$repo"; return; fi
  open_pane "$1" "$repo"
}

# One dashboard per repo: a second press goes back to it. A new one opens as a tab of the repo's
# own workspace, also when the key is pressed in one of its streams.
open_dashboard() { # repo
  local ws
  dash_focus_existing "$1" && return
  ws=$(repo_workspace "$1")
  open_pane dashboard "$1" ${ws:+--workspace "$ws"}
}

# --- pane helpers (stdin is the pane's terminal; tests feed it a script) -------------------------

eof=0
ask() { # var prompt [default]
  local __v
  if ! IFS= read -r -e -p "$2${3:+ [$3]}: " __v; then eof=1; __v=""; fi
  printf -v "$1" '%s' "${__v:-${3:-}}"
}

confirm() { # prompt default(y|n)
  local a; ask a "$1 $( [[ $2 == y ]] && echo '[Y/n]' || echo '[y/N]')"
  a=${a:-$2}; [[ $a == [yY]* ]]
}

have_fzf() { [[ -z ${HERD_NO_FZF:-} && -t 0 ]] && command -v fzf >/dev/null; }

# pick var title item...  — one item, by number or with fzf. Fails on cancel or no items.
pick() {
  local __var=$1 title=$2 __a i; shift 2
  (($#)) || return 1
  if have_fzf; then
    __a=$(printf '%s\n' "$@" | fzf --height=40% --reverse --prompt="$title> ") || return 1
    printf -v "$__var" '%s' "$__a"; return
  fi
  echo "$title"
  for ((i = 1; i <= $#; i++)); do printf '  %2d  %s\n' "$i" "${!i}"; done
  ask __a "number"
  [[ $__a =~ ^[0-9]+$ ]] && ((__a >= 1 && __a <= $#)) || return 1
  printf -v "$__var" '%s' "${!__a}"
}

# pick_many array title item...  — several, as "1 3", "a" for all, or fzf -m (Tab).
pick_many() {
  local -n __out=$1; local title=$2 __a i n; shift 2
  __out=(); (($#)) || return 1
  if have_fzf; then
    mapfile -t __out < <(printf '%s\n' "$@" | fzf -m --height=40% --reverse --prompt="$title (Tab marks)> ")
    ((${#__out[@]})); return
  fi
  echo "$title"
  for ((i = 1; i <= $#; i++)); do printf '  %2d  %s\n' "$i" "${!i}"; done
  ask __a "numbers (e.g. 1 3), a for all"
  if [[ $__a == a ]]; then __out=("$@"); return; fi
  for n in $__a; do
    [[ $n =~ ^[0-9]+$ ]] && ((n >= 1 && n <= $#)) && __out+=("${!n}")
  done
  ((${#__out[@]}))
}

editor_file() { # path: open it in the user's editor
  "${VISUAL:-${EDITOR:-vi}}" "$1"
}

hr() { printf '%s\n' "------------------------------------------------------------------"; }
pause() { echo; read -rsn1 -p "press any key to close " _ || true; echo; }

need_repo() {
  if [[ -z $repo ]]; then
    echo "herd: focus a pane inside a git repo, then run this again."
    return 1
  fi
}

# Streams of $repo as "branch<TAB>status<TAB>plan" lines.
streams() {
  run_herd status -j -r "$repo" | jq -r '[.branch, .status, (if .plan == "" then "-" else .plan end)] | @tsv'
}

# --- panes ----------------------------------------------------------------------------------------

menu_items=(
  "dashboard    Dashboard: live view of every stream, with actions"
  "fanout       Fan out a task file (one agent per line)"
  "draft        Draft a task file from a goal"
  "plan         Run a plan as gated stages"
  "plan-resume  Resume a stopped plan"
  "status       Status of this repo's streams"
  "done         Done: clean up merged streams"
  "rm           Discard streams (no checks)"
  "personas     Personas"
  "settings     Settings"
  "version      Version"
)

pane_menu() {
  local choice id
  while :; do
    clear 2>/dev/null; echo "herd  ${repo:-(no repo)}"; hr
    pick choice "herd" "${menu_items[@]}" || return 0
    id=${choice%% *}
    case $id in
      # A plan runs for hours, so it gets its own tab instead of this overlay.
      plan | plan-resume) open_pane "$id" "$repo"; return ;;
      dashboard) if need_repo; then open_dashboard "$repo"; else pause; fi; return ;;
      version) run_herd --version; pause ;;
      *) "pane_${id//-/_}"; [[ $id == status ]] || pause ;;
    esac
    ((eof)) && return
  done
}

# The task files in the repo root: Tasks.herd first, then any other *.herd.
task_files() {
  local f
  [[ -f $repo/Tasks.herd ]] && echo "$repo/Tasks.herd"
  for f in "$repo"/*.herd; do [[ -f $f && $f != "$repo/Tasks.herd" ]] && echo "$f"; done
}

# Fan out task file $1 (or one picked here) after a dry run and a yes.
pane_fanout() {
  need_repo || return
  local file=${1:-} files persona out names
  if [[ -z $file ]]; then
    mapfile -t files < <(task_files)
    if ((${#files[@]} == 0)); then
      echo "no task file in $repo. Draft one (herd: Draft), or write Tasks.herd:"
      echo "  fix/foo @engineer: Fix foo. Run make test, open a PR."
      return
    fi
    if ((${#files[@]} == 1)); then file=${files[0]}
    else pick file "task file" "${files[@]}" || return; fi
  fi
  echo "task file: $file"
  ask persona "persona for lines without @persona (empty: none)" "$HERD_PERSONA"
  hr; echo "would start:"
  run_herd -n -r "$repo" ${persona:+-P "$persona"} -f "$file" || return; hr
  confirm "start them (base $HERD_BASE, $HERD_KIND${HERD_AGENT_ARGS:+, args $HERD_AGENT_ARGS})?" y || return
  out=$(mktemp)
  run_herd -r "$repo" -b "$HERD_BASE" -k "$HERD_KIND" ${persona:+-P "$persona"} -f "$file" \
    ${agent_args[0]:+-- "${agent_args[@]}"} 2>&1 | tee "$out"
  mapfile -t names < <(sed -n 's/^started \([^ ]*\) .*/\1/p' "$out"); rm -f "$out"
  ((${#names[@]})) || return
  record_batch "${names[@]}"
  echo; echo "${#names[@]} agent(s) started. herd notifies when they have all finished (HERD_NOTIFY=$HERD_NOTIFY)."
}

# A fan-out batch, for the event hook: the repo, then one agent name per line.
record_batch() {
  [[ $HERD_NOTIFY == off ]] && return
  mkdir -p "$state_dir/batches"
  { echo "# $repo"; printf '%s\n' "$@"; } >"$state_dir/batches/$(date +%s)-$$"
}

pane_draft() {
  need_repo || return
  local goal tmp out def force=()
  echo "Draft a task file: a read-only dispatcher agent reads $repo and splits the goal into"
  echo "parallel tasks, one 'branch @persona: prompt' line each. Takes a minute or two."; hr
  ask goal "goal (empty: write it in ${VISUAL:-${EDITOR:-vi}})"
  if [[ -z $goal ]]; then
    ((eof)) && return
    mkdir -p "$state_dir"; tmp=$(mktemp "$state_dir/goal.XXXXXX.md")
    editor_file "$tmp"
    [[ -s $tmp ]] || { echo "empty goal, nothing drafted"; rm -f "$tmp"; return; }
    goal=$tmp
  fi
  def=Tasks.herd; [[ -e $repo/$def ]] && def="Tasks-$(date +%Y%m%d-%H%M).herd"
  ask out "write to (in $repo)" "$def"
  [[ $out == /* ]] || out=$repo/$out
  if [[ -e $out ]]; then confirm "$out exists, overwrite it?" n || return; force=(-F); fi
  run_herd draft -r "$repo" -b "$HERD_BASE" -o "$out" "${force[@]}" "$goal" \
    ${draft_args[0]:+-- "${draft_args[@]}"} || { [[ -n ${tmp:-} ]] && echo "goal kept in $tmp"; return; }
  [[ -n ${tmp:-} ]] && rm -f "$tmp"
  hr
  if confirm "fan out $(basename "$out") now?" n; then pane_fanout "$out"; fi
}

pane_plan() {
  need_repo || return
  local branch src files=() f verify persona dry=() tmp="" rc
  echo "Run a plan: one worktree, one branch, a chain of gated stages, one PR at the end."; hr
  while :; do
    ask branch "branch (e.g. feat/export-csv)"
    [[ -n $branch ]] || return
    git check-ref-format --branch "$branch" >/dev/null 2>&1 && break
    echo "  not a valid branch name"; ((eof)) && return
  done
  for f in "$repo"/*.md; do [[ -f $f ]] && files+=("$(basename "$f")"); done
  pick src "plan" "${files[@]}" "(write it in ${VISUAL:-${EDITOR:-vi}})" || return
  if [[ $src == "("* ]]; then
    mkdir -p "$state_dir"; tmp=$(mktemp "$state_dir/plan.XXXXXX.md")
    editor_file "$tmp"
    [[ -s $tmp ]] || { echo "empty plan, nothing started"; rm -f "$tmp"; return; }
    src=$tmp
  else
    src=$repo/$src
  fi
  ask verify "default verify command for stages without one (empty: none)"
  ask persona "stage persona" "${HERD_PERSONA:-engineer}"
  confirm "stop after planning, to review the stages first?" n && dry=(-n)
  hr
  run_herd plan -r "$repo" -b "$HERD_BASE" -k "$HERD_KIND" ${verify:+-v "$verify"} -P "$persona" "${dry[@]}" \
    "$branch" "$src" ${agent_args[0]:+-- "${agent_args[@]}"}
  rc=$?
  [[ -n $tmp ]] && rm -f "$tmp"
  plan_notify "$branch" "$rc"
}

plan_notify() { # branch rc
  [[ $HERD_NOTIFY == off ]] && return
  if (($2 == 0)); then notify "herd: plan $1 ended" "Check its tab; after the PR merges, run herd: Done." "done"
  else notify "herd: plan $1 stopped" "See its tab for why, then herd: Resume a plan." request; fi
}

pane_plan_resume() {
  need_repo || return
  local rows=() row branch
  if [[ -n ${HERD_BRANCH:-} ]]; then
    branch=$HERD_BRANCH   # the dashboard's r: that stream's plan
  else
    mapfile -t rows < <(streams | awk -F'\t' '$3 != "-" && $3 != "complete"')
    if ((${#rows[@]} == 0)); then echo "no stopped plans in $repo"; return; fi
    pick row "plan to resume" "${rows[@]}" || return
    branch=${row%%$'\t'*}
  fi
  hr; run_herd plan -r "$repo" -R "$branch"
  plan_notify "$branch" $?
}

pane_status() {
  need_repo || return
  local k
  while :; do
    clear 2>/dev/null; echo "herd status  $repo  ($(date +%T))"; hr
    run_herd status -r "$repo"
    echo; echo "r refresh   q close   (refreshes every 10 s)"
    if IFS= read -rsn1 -t 10 k; then [[ $k == [qQ] ]] && return
    else (($? > 128)) || return; fi   # >128 is the timeout; anything else is EOF
  done
}

pane_done() {
  need_repo || return
  local rows=() sel=() branches=() r
  mapfile -t rows < <(streams)
  if ((${#rows[@]} == 0)); then echo "no herd streams in $repo"; return; fi
  echo "Done removes a stream only if its PR is merged, nothing is left unmerged, its agent is idle"
  echo "and its tree is clean; anything else is skipped and says why."; hr
  pick_many sel "streams to close" "${rows[@]}" || return
  for r in "${sel[@]}"; do branches+=("${r%%$'\t'*}"); done
  hr; run_herd "done" -r "$repo" -b "$HERD_BASE" "${branches[@]}"
}

pane_rm() {
  need_repo || return
  local rows=() sel=() branches=() r a
  mapfile -t rows < <(streams)
  if ((${#rows[@]} == 0)); then echo "no herd streams in $repo"; return; fi
  echo "Discard removes worktree, workspace and local branch with NO checks: uncommitted and"
  echo "unpushed work in them is lost. Use Done for merged streams."; hr
  pick_many sel "streams to discard" "${rows[@]}" || return
  for r in "${sel[@]}"; do branches+=("${r%%$'\t'*}"); done
  ask a "type discard to remove ${branches[*]}"
  [[ $a == discard ]] || { echo "nothing removed"; return; }
  run_herd rm -r "$repo" "${branches[@]}"
}

pane_personas() {
  local names=() n
  mapfile -t names < <(run_herd personas | awk '{print $1}')
  while :; do
    clear 2>/dev/null; run_herd personas | cut -c1-"${COLUMNS:-120}"; hr
    pick n "read which persona (empty closes)" "${names[@]}" || return 0
    if command -v less >/dev/null && [[ -t 1 ]]; then run_herd personas "$n" | less -R
    else run_herd personas "$n"; pause; fi
    ((eof)) && return
  done
}

pane_settings() {
  mkdir -p "$conf_dir"
  [[ -f $conf ]] || conf_template >"$conf"
  editor_file "$conf"
  echo "saved $conf; herd reads it at the start of every action."
}

pane() {
  load_conf
  repo=$(resolve_repo) || repo=""
  [[ -z $repo ]] || cd "$repo" || repo=""
  case $1 in
    menu) pane_menu ;;
    status) pane_status ;;
    dashboard) pane_dashboard ;;
    fanout | draft | plan | plan-resume | "done" | rm | personas | settings) "pane_${1//-/_}"; pause ;;
    *) echo "herd: unknown pane '$1'"; pause; return 2 ;;
  esac
}

# --- the event hook -------------------------------------------------------------------------------

# The herd worktree (~/git/wt/<repo>/<name>) that dir $1 is in, if any.
herd_wt() {
  local rest=${1#"$HOME/git/wt/"} r n
  [[ $rest != "$1" && $rest == */* ]] || return 1
  r=${rest%%/*} n=${rest#*/} n=${n%%/*}
  [[ -n $r && -n $n ]] || return 1
  echo "$HOME/git/wt/$r/$n"
}

# Tells a running herd serve to send a fresh snapshot now. Its state dir is herd's own (bin/herd
# serve_state_dir), not this plugin's; it exists once herd serve has run.
serve_nudge() {
  local d=${HERD_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herd}
  [[ -d $d ]] && touch "$d/serve.nudge" 2>/dev/null
  return 0
}

# A plan's state value $2 (stage, status) in worktree $1, or nothing.
plan_state() { sed -n "s/^$2=//p" "$1/.herd/run/state" 2>/dev/null; }

event_hook() {
  load_conf
  local ev=${HERDR_PLUGIN_EVENT_JSON:-} pane st agents row cwd name wt prev key token pstatus
  # A worktree came or went: only open dashboards care.
  case ${HERDR_PLUGIN_EVENT:-} in
    worktree.*) dash_tick; serve_nudge; return 0 ;;
  esac
  pane=$(jq -r '.data.pane_id // empty' <<<"$ev" 2>/dev/null)
  st=$(jq -r '.data.agent_status // empty' <<<"$ev" 2>/dev/null)
  [[ -n $pane && -n $st ]] || return 0
  agents=$(herdr agent list 2>/dev/null) || return 0
  row=$(jq -c --arg p "$pane" 'first(.result.agents[] | select(.pane_id == $p)) // empty' <<<"$agents")
  cwd=$(jq -r '.cwd // empty' <<<"$row")
  wt=$(herd_wt "$cwd") || return 0
  name=$(jq -r '.name // empty' <<<"$row"); name=${name:-$(basename "$wt")}

  dash_tick; serve_nudge
  mkdir -p "$state_dir/panes"
  key=$state_dir/panes/${pane//[^A-Za-z0-9_-]/_}
  prev=$(cat "$key" 2>/dev/null); echo "$st" >"$key"
  pstatus=$(plan_state "$wt" status)

  if [[ $HERD_SIDEBAR == 1 ]]; then
    if [[ -n $pstatus ]]; then token=$(run_herd_plan_label "$wt")
    else token=$(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null); fi
    herdr pane report-metadata "$pane" --source herd --token "herd=${token:-herd}" >/dev/null 2>&1 || true
  fi

  [[ $HERD_NOTIFY == off ]] && return 0
  if [[ $HERD_NOTIFY == all ]]; then
    if [[ $st == blocked && $prev != blocked ]]; then
      notify "herd: $name needs input" "${pstatus:+plan $(run_herd_plan_label "$wt"), }$wt" request
    # A plan's agent goes idle between every stage; its pane reports the end instead.
    elif [[ $st == idle || $st == "done" ]] && [[ $prev == working && ( -z $pstatus || $pstatus == complete ) ]]; then
      notify "herd: $name finished" "$wt" "done"
    fi
  fi
  [[ $st == idle || $st == "done" ]] && check_batches "$agents"
  return 0
}

# A plan's label, the way herd status shows it.
run_herd_plan_label() {
  # shellcheck source=/dev/null
  (source "$herd" && plan_label "$1")
}

# Notifies once for each fan-out batch whose agents have all finished, then forgets it.
check_batches() {
  local f names=() n s busy repo_line
  for f in "$state_dir"/batches/*; do
    [[ -f $f && $f != *.notified ]] || continue
    mapfile -t names < <(grep -v '^#' "$f")
    busy=0
    for n in "${names[@]}"; do
      s=$(jq -r --arg n "$n" 'first(.result.agents[] | select(.name == $n) | .agent_status) // "gone"' <<<"$1")
      [[ $s == idle || $s == "done" || $s == gone ]] || { busy=1; break; }
    done
    ((busy)) && continue
    # Two hooks can finish together; only the one that wins the rename notifies.
    mv "$f" "$f.notified" 2>/dev/null || continue
    repo_line=$(sed -n '1s/^# //p' "$f.notified")
    notify "herd: batch finished (${#names[@]} agent(s))" \
      "${names[*]} in $(basename "$repo_line"). Review the PRs, then herd: Done." "done"
    rm -f "$f.notified"
  done
}

usage() { sed -n '2,7s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"; }

# Sourced (by tests/plugin.sh): define the functions above, run nothing.
[[ ${BASH_SOURCE[0]} == "$0" ]] || return 0

case ${1:-} in
  action) action "${2:-}" ;;
  pane) pane "${2:-}" ;;
  event) event_hook ;;
  *) usage; exit 2 ;;
esac
