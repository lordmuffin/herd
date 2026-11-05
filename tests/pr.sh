#!/usr/bin/env bash
# Tests for pr_lookup, the PR check behind herd done and herd plan's last-stage gate: github.com
# origins ask gh, every other host asks Forgejo with fj's token, and "can't check" is told apart
# from "no PR". gh and curl are faked; nothing reaches a network.
#
#   bash tests/pr.sh        (make test runs it)
# shellcheck disable=SC2034  # the globals set here are herd's, read by the functions sourced below
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=/dev/null
source "$here/../bin/herd"
set +e

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; [[ -z ${2:-} ]] || sed 's/^/       /' <<<"$2"; }
check() { local name=$1; shift; if "$@"; then ok "$name"; else bad "$name" "$(cat "$T/out" "$T/calls" 2>/dev/null)"; fi; }

# --- the fakes ----------------------------------------------------------------------------------
# GH_OUT: what `gh pr list` prints; GH_RC: its exit code; NO_GH=1: gh is not installed.
# CURL_OUT / CURL_RC: the same for the Forgejo API call.
gh() { echo "gh $*" >>"$T/calls"; printf '%s' "$GH_OUT"; return "${GH_RC:-0}"; }
curl() { echo "curl $*" >>"$T/calls"; printf '%s' "$CURL_OUT"; return "${CURL_RC:-0}"; }
have() { [[ $1 == gh && ${NO_GH:-0} == 1 ]] && return 1; command -v "$1" >/dev/null || declare -F "$1" >/dev/null; }

setup() {
  T=$(mktemp -d)
  export HOME=$T XDG_DATA_HOME=$T/xdg
  repo=$T/proj
  git init -q -b main "$repo"
  GH_OUT="" GH_RC=0 NO_GH=0 CURL_OUT="" CURL_RC=0
}
origin() { git -C "$repo" remote remove origin 2>/dev/null; git -C "$repo" remote add origin "$1"; }
fj_token() {   # a keys.json with a token for host $1
  mkdir -p "$XDG_DATA_HOME/forgejo-cli"
  jq -n --arg h "$1" '{hosts: {($h): {token: "secret"}}, aliases: {}}' >"$XDG_DATA_HOME/forgejo-cli/keys.json"
}
look() { pr=$(pr_lookup main feat/x 2>"$T/out"); rc=$?; }
field() { jq -r ".$1" <<<"$pr"; }

echo "github.com origin"
for url in https://github.com/o/r.git git@github.com:o/r.git ssh://git@github.com/o/r; do
  setup; origin "$url"; GH_OUT='[{"number":317,"state":"OPEN","url":"https://github.com/o/r/pull/317"}]'; look
  check "$url: asks gh for o/r, head feat/x into main" \
    grep -q -- 'gh pr list --repo o/r --head feat/x --base main --state all' "$T/calls"
  check "$url: found, open, not merged" eval 'test $rc -eq 0 -a "$(field number)" = 317 -a "$(field state)" = open -a "$(field merged)" = false'
done

setup; origin git@github.com:o/r.git; GH_OUT='[{"number":9,"state":"MERGED","url":"u"}]'; look
check "merged PR: merged true, html_url kept" eval 'test $rc -eq 0 -a "$(field merged)" = true -a "$(field html_url)" = u'

setup; origin git@github.com:o/r.git; GH_OUT='[]'; look
check "no PR: exit 1" test "$rc" -eq 1

setup; origin git@github.com:o/r.git; GH_RC=4; look
check "gh fails (auth, network): exit 2, not 'no PR'" eval 'test $rc -eq 2 && grep -q "gh" "$T/out"'

setup; origin git@github.com:o/r.git; NO_GH=1; look
check "no gh: exit 2, never asks Forgejo" eval 'test $rc -eq 2 && ! grep -q curl "$T/calls" 2>/dev/null'

echo "Forgejo origin"
setup; origin ssh://git@git.example.dev/o/r.git; look
check "no keys.json: exit 2" test "$rc" -eq 2

setup; origin ssh://git@git.example.dev/o/r.git; fj_token other.dev; look
check "no token for this host: exit 2" eval 'test $rc -eq 2 && grep -q "no fj token for git.example.dev" "$T/out"'

setup; origin ssh://git@git.example.dev/o/r.git; fj_token git.example.dev
CURL_OUT='{"number":5,"state":"open","merged":false,"html_url":"h"}'; look
check "found: the API's JSON, from pulls/main/feat/x" \
  eval 'test $rc -eq 0 -a "$(field number)" = 5 && grep -q "repos/o/r/pulls/main/feat/x" "$T/calls"'

setup; origin ssh://git@git.example.dev/o/r.git; fj_token git.example.dev; CURL_RC=22; look
check "API says no: exit 1" test "$rc" -eq 1

echo "the plan gate"
setup; origin git@github.com:o/r.git; plan_branch=feat/x base=origin/main
check "github PR open: no PR message" eval 'GH_OUT='"'"'[{"number":1,"state":"OPEN","url":"u"}]'"'"'; test -z "$(stage_pr_msg)"'
check "github, no PR: says so" eval 'GH_OUT="[]"; stage_pr_msg | grep -q "There is no PR from feat/x into main"'
check "github, gh fails: skipped with a note, not a failure" \
  eval 'GH_OUT="" GH_RC=4; test -z "$(stage_pr_msg 2>/dev/null)" && stage_pr_msg 2>&1 | grep -q "could not check"'

echo "$pass passed, $fail failed"
((fail == 0))
