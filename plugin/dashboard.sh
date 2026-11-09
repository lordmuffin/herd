# shellcheck shell=bash
# shellcheck disable=SC2154 # repo, state_dir, eof and HERD_BASE belong to herd-plugin.sh
# herd's dashboard: a full-screen view of one repo's streams, in a herdr plugin pane. Sourced by
# herd-plugin.sh, whose helpers (run_herd, ask, confirm, pause, open_pane, the pane_* forms) it
# uses. Plain bash and jq, like the rest of herd: no build step, nothing new to install.
#
# Data comes from `herd status -j` (git facts and plan stages included, so that logic lives in
# bin/herd only), plus each stream's PROGRESS.md and agent screen. It redraws when the
# plugin's event hook touches $state_dir/tick (an agent of a herd stream changed status, a
# worktree came or went), and every HERD_DASH_POLL seconds regardless.
#
# With stdout not a terminal (the tests), it skips the alternate screen and colours and prints
# each frame in turn, and quits when stdin runs out.

HERD_DASH_POLL=${HERD_DASH_POLL:-5}

dash_keys_help=(
  "j/k, arrows  select a stream          enter, o  go to its workspace"
  "s  its agent's screen   v  diff vs base   l  plan progress log"
  "d  done (merged)   x  discard   r  resume its plan"
  "f  fan out   n  draft a task file   p  start a plan"
  "g  refresh   ?  keys   q  quit"
)

# --- data -------------------------------------------------------------------------------------

# Streams of $repo into the D_* arrays, one index per stream; D_JSON holds each one's whole
# `herd status -j` object.
dash_load() {
  local line b a s p pa w
  D_BR=() D_AG=() D_ST=() D_PL=() D_PATH=() D_WS=() D_JSON=()
  while IFS= read -r line; do
    IFS=$'\t' read -r b a s p pa w < <(jq -r '[.branch, .agent, .status,
      (if .plan == "" then "-" else .plan end), .path, .workspace] | @tsv' <<<"$line" 2>/dev/null) || continue
    D_BR+=("$b") D_AG+=("$a") D_ST+=("$s") D_PL+=("$p") D_PATH+=("$pa") D_WS+=("$w") D_JSON+=("$line")
  done < <(run_herd status -j -b "$HERD_BASE" -r "$repo" 2>/dev/null)
  ((sel < ${#D_BR[@]})) || sel=$((${#D_BR[@]} - 1))
  ((sel >= 0)) || sel=0
  touch "$dash_mark"
}

# "2 working · 1 blocked · 3 idle", in a fixed order.
dash_counts() {
  local s n out=""
  declare -A c=()
  for s in "${D_ST[@]}"; do s=${s:--}; c[$s]=$((${c[$s]:-0} + 1)); done
  for s in blocked working idle "done" unknown -; do
    n=${c[$s]:-0}; ((n)) || continue
    out+="${out:+ · }$n ${s/#-/no agent}"
  done
  echo "$out"
}

# The plan's stages from a stream's JSON ($1), one per line: "<mark> <n> <title>", the mark being
# ✓ done, ▶ current, ! stopped there, · to come. Nothing when the stream has no plan.
dash_stages() {
  jq -r '.plan_detail // empty
    | if (.stages | length) == 0 then "  ▶ \(.status // "-")"
      else .stages[] | "  \({done: "✓", current: "▶", stopped: "!", todo: "·"}[.state]) \(.n) \(.title)" end' \
    <<<"$1" 2>/dev/null
}

# git facts from a stream's JSON ($1): commits ahead of the base, uncommitted files, the last commit.
dash_git() {
  local p
  p=$(jq -r .path <<<"$1")
  [[ -d $p ]] || { echo "  (worktree missing: $p)"; return; }
  jq -r --arg base "$HERD_BASE" '
    "  \(.ahead // "?") commit(s) ahead of \($base) · \(.dirty // "?") uncommitted file(s)",
    (.last_commit // empty | "  last: \(.sha) \(.subject) (\(.rel_time))")' <<<"$1" 2>/dev/null
}

# The last few lines that say something, from a file or a command's output on stdin.
dash_tail() { # n
  grep -v -e '^[[:space:]]*$' -e '^[[:space:]]*[─━-]\{3,\}[[:space:]]*$' | tail -n "$1"
}

# --- drawing ----------------------------------------------------------------------------------

dash_size() {
  local r c
  if [[ $dash_tty == 1 ]] && read -r r c < <(stty size </dev/tty 2>/dev/null); then
    D_ROWS=$r D_COLS=$c
  else
    D_ROWS=${LINES:-40} D_COLS=${COLUMNS:-100}
  fi
}

# Colours only on a terminal; the tests read plain text.
dash_c() { [[ $dash_tty == 1 ]] && printf '\e[%sm' "$1"; }

dash_status_color() {
  case $1 in
    blocked) echo "1;31" ;; working) echo "33" ;; idle | "done") echo "32" ;; *) echo "2" ;;
  esac
}

# Appends one line to the frame, cut to the width. $2 is an SGR code for the whole line.
dash_line() {
  local s=${1:0:$D_COLS}
  if [[ -n ${2:-} ]]; then frame+=$(dash_c "$2")$s$(dash_c 0)$'\n'; else frame+=$s$'\n'; fi
  ((++used))
}

dash_draw() {
  local i mark st branch row left n path agent_lines stages
  dash_size
  frame="" used=0
  dash_line "herd  ${repo/#$HOME/\~}   ${#D_BR[@]} stream(s)${D_BR[0]:+: $(dash_counts)}   $(date +%H:%M:%S)" 1
  dash_line "$(printf '%*s' "$D_COLS" '' | tr ' ' '-')" 2
  if ((${#D_BR[@]} == 0)); then
    dash_line ""
    dash_line "  no herd streams in this repo yet."
    dash_line "  f fans out a task file, n drafts one from a goal, p runs a plan."
  else
    dash_line "$(printf '  %-34s %-9s %-22s %s' BRANCH STATUS PLAN WORKSPACE)" 2
    for i in "${!D_BR[@]}"; do
      mark="  "; ((i == sel)) && mark="> "
      st=${D_ST[i]}
      row=$(printf '%s%-34.34s %-9s %-22.22s %s' "$mark" "${D_BR[i]}" "$st" "${D_PL[i]}" "${D_WS[i]}")
      if ((i == sel)); then dash_line "$row" 7; else dash_line "$row" "$(dash_status_color "$st")"; fi
    done
    # The selected stream in detail.
    i=$sel branch=${D_BR[i]} path=${D_PATH[i]} st=${D_ST[sel]}
    dash_line ""
    dash_line "$branch   agent ${D_AG[i]} ($st)   ${path/#$HOME/\~}" 1
    stages=$(dash_stages "${D_JSON[i]}")
    if [[ -n $stages ]]; then
      dash_line "plan  ${D_PL[i]}" 2
      while IFS= read -r row; do dash_line "$row"; done <<<"$stages"
    fi
    dash_line "git" 2
    while IFS= read -r row; do dash_line "$row"; done < <(dash_git "${D_JSON[i]}")
    if [[ -f $path/.herd/run/PROGRESS.md ]]; then
      dash_line "progress (.herd/run/PROGRESS.md)" 2
      while IFS= read -r row; do dash_line "  $row"; done < <(dash_tail 4 <"$path/.herd/run/PROGRESS.md")
    fi
    # The agent's screen fills what is left, less the footer.
    left=$((D_ROWS - used - 4))
    if [[ ${D_ST[i]} != - ]] && ((left > 1)); then
      n=$((left > 12 ? 12 : left - 1))
      agent_lines=$(herdr agent read "${D_AG[i]}" --source recent-unwrapped --lines 40 2>/dev/null | dash_tail "$n")
      if [[ -n $agent_lines ]]; then
        dash_line "agent screen (s for more)" 2
        while IFS= read -r row; do dash_line "  $row"; done <<<"$agent_lines"
      fi
    fi
  fi
  # Footer at the bottom of a terminal; straight after the body otherwise.
  if [[ $dash_tty == 1 ]]; then
    while ((used < D_ROWS - 2)); do frame+=$'\n'; ((++used)); done
  fi
  dash_line "${dash_flash:-enter go  d done  x discard  r resume  f fan out  n draft  p plan  v diff  s screen  ? keys  q quit}" 2
  dash_flash=""
  if [[ $dash_tty == 1 ]]; then printf '\e[H\e[2J%s' "${frame%$'\n'}"
  else printf '%s' "$frame"; echo "-- end of frame"; fi
}

dash_enter() {
  [[ $dash_tty == 1 ]] || return 0
  printf '\e[?1049h\e[?25l'
  stty -echo 2>/dev/null || true
}
dash_leave() {
  [[ $dash_tty == 1 ]] || return 0
  stty echo 2>/dev/null || true
  printf '\e[?25h\e[?1049l'
}

# --- actions on the selected stream ---------------------------------------------------------

# Run a form or command outside the dashboard's screen, wait for a key, come back.
dash_run() {
  dash_leave; clear 2>/dev/null
  "$@"
  pause
  dash_enter; dash_load
}

dash_page() { # page through stdin
  if [[ $dash_tty == 1 ]] && command -v less >/dev/null; then less -R; else cat; pause; fi
}

# Go to the stream: its open workspace, else its agent, else reopen its worktree as a workspace.
dash_go() {
  local i=$sel
  if [[ ${D_WS[i]} != - ]] && herdr workspace focus "${D_WS[i]}" >/dev/null 2>&1; then
    dash_flash="went to workspace ${D_WS[i]} (${D_BR[i]})"; return
  fi
  if [[ ${D_ST[i]} != - ]] && herdr agent focus "${D_AG[i]}" >/dev/null 2>&1; then
    dash_flash="went to agent ${D_AG[i]}"; return
  fi
  if herdr worktree open --cwd "$repo" --path "${D_PATH[i]}" --focus >/dev/null 2>&1; then
    dash_flash="reopened ${D_BR[i]} as a workspace"; dash_load
  else
    dash_flash="could not open ${D_BR[i]}: no workspace, no agent, and worktree open failed"
  fi
}

dash_done() {
  echo "Done removes ${D_BR[sel]} only if its PR is merged, nothing is left unmerged, its agent is"
  echo "idle and its tree is clean; otherwise it says why and keeps it."; hr
  confirm "run herd done on ${D_BR[sel]}?" y || return 0
  run_herd "done" -r "$repo" -b "$HERD_BASE" "${D_BR[sel]}"
}

dash_discard() {
  local a
  echo "Discard removes the worktree, workspace and local branch of ${D_BR[sel]} with NO checks:"
  echo "uncommitted and unpushed work in it is lost."; hr
  ask a "type discard to remove ${D_BR[sel]}"
  [[ $a == discard ]] || { echo "nothing removed"; return 0; }
  run_herd rm -r "$repo" "${D_BR[sel]}"
}

dash_resume() {
  local p=${D_PL[sel]}
  if [[ $p == - || $p == complete ]]; then dash_flash="${D_BR[sel]} has no stopped plan"; return; fi
  open_pane plan-resume "$repo" "HERD_BRANCH=${D_BR[sel]}"
  dash_flash="resuming ${D_BR[sel]}'s plan in a new tab"
}

dash_diff() {
  local p=${D_PATH[sel]}
  [[ -d $p ]] || { dash_flash="worktree missing"; return; }
  dash_leave
  { git -C "$p" log --oneline "$HERD_BASE..HEAD" 2>/dev/null; echo
    git -C "$p" diff --stat "$HERD_BASE" 2>/dev/null; echo
    git -C "$p" -c color.ui="$([[ $dash_tty == 1 ]] && echo always || echo never)" diff "$HERD_BASE" 2>/dev/null
  } | dash_page
  dash_enter
}

dash_log() {
  local f=${D_PATH[sel]}/.herd/run/PROGRESS.md
  [[ -f $f ]] || { dash_flash="${D_BR[sel]} has no plan progress log"; return; }
  dash_leave; dash_page <"$f"; dash_enter
}

dash_screen() {
  [[ ${D_ST[sel]} != - ]] || { dash_flash="${D_BR[sel]} has no live agent"; return; }
  dash_leave
  herdr agent read "${D_AG[sel]}" --source recent-unwrapped --lines 200 2>&1 | dash_page
  dash_enter
}

dash_help() {
  dash_leave; clear 2>/dev/null
  echo "herd dashboard keys"; hr
  printf '  %s\n' "${dash_keys_help[@]}"
  echo; echo "It refreshes when a herd agent changes status, and every $HERD_DASH_POLL s."
  pause
  dash_enter
}

# --- the loop ---------------------------------------------------------------------------------

# The event hook's nudge: open dashboards reload when this file is newer than their last load.
dash_tick() { mkdir -p "$state_dir" && touch "$state_dir/tick"; }

# Where a repo's open dashboard records its pane, so a second open focuses that one.
dash_reg() { echo "$state_dir/dashboards/$(printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_')"; }

# Focus the repo's dashboard if one is open. Fails if there is none to focus.
dash_focus_existing() {
  local f p
  f=$(dash_reg "$1"); p=$(cat "$f" 2>/dev/null) || return 1
  [[ -n $p ]] && herdr pane get "$p" >/dev/null 2>&1 || { rm -f "$f"; return 1; }
  herdr plugin pane focus "$p" >/dev/null 2>&1
}

dash_cleanup() {
  dash_leave
  [[ -n ${dash_regfile:-} && $(cat "$dash_regfile" 2>/dev/null) == "${HERDR_PANE_ID:-}" ]] && rm -f "$dash_regfile"
  rm -f "$dash_mark"
}

pane_dashboard() {
  need_repo || { pause; return; }
  local k rest last dirty=1 n
  sel=0 dash_flash=""
  dash_tty=0; [[ -t 0 && -t 1 ]] && dash_tty=1
  mkdir -p "$state_dir/dashboards"
  dash_mark=$(mktemp "$state_dir/dashboards/.mark.XXXXXX")
  if [[ -n ${HERDR_PANE_ID:-} ]]; then dash_regfile=$(dash_reg "$repo"); echo "$HERDR_PANE_ID" >"$dash_regfile"; fi
  trap dash_cleanup EXIT
  trap 'dirty=1' WINCH
  dash_enter
  dash_load; last=$SECONDS
  while :; do
    if ((dirty)); then dash_draw; dirty=0; fi
    if IFS= read -rsn1 -t 1 k; then
      if [[ $k == $'\e' ]]; then read -rsn2 -t 0.05 rest || true; k+=$rest; fi
      n=${#D_BR[@]}
      case $k in
        q | Q) return 0 ;;
        j | $'\e[B') ((n && sel < n - 1)) && ((++sel)) ;;
        k | $'\e[A') ((sel > 0)) && ((--sel)) ;;
        g | G) dash_load ;;
        "?") dash_help ;;
        f) dash_run pane_fanout ;;
        n) dash_run pane_draft ;;
        p) open_pane plan "$repo"; dash_flash="started the plan form in a new tab" ;;
        "" | o)       ((n)) && dash_go ;;
        d)            ((n)) && dash_run dash_done ;;
        x)            ((n)) && dash_run dash_discard ;;
        r)            ((n)) && dash_resume ;;
        v)            ((n)) && dash_diff ;;
        l)            ((n)) && dash_log ;;
        s)            ((n)) && dash_screen ;;
        *) continue ;;
      esac
      dirty=1
      ((eof)) && return 0
    else
      (($? > 128)) || return 0   # EOF on stdin: the pane is going away (or the test is over)
      # An event, or the poll interval: reload and redraw.
      if [[ $state_dir/tick -nt $dash_mark ]] || ((SECONDS - last >= HERD_DASH_POLL)); then
        dash_load; last=$SECONDS; dirty=1
      fi
    fi
  done
}
