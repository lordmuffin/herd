#!/usr/bin/env bash
# Tests for herd version: the dev checkout reads VERSION, an installed copy reads share/herd/VERSION.
#
#   bash tests/version.sh        (make test runs it)
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
root=$here/..
want=$(head -n1 "$root/VERSION")

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "  ok   $1"; }
bad() { fail=$((fail + 1)); echo "  FAIL $1"; [[ -z ${2:-} ]] || sed 's/^/       /' <<<"$2"; }

out=$("$root/bin/herd" --version)
if [[ $out == "herd $want"* ]]; then ok "dev checkout reports VERSION"; else bad "dev checkout reports VERSION" "$out"; fi

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
make -s -C "$root" install DESTDIR="$T" PREFIX=/usr >/dev/null
out=$("$T/usr/bin/herd" version)
if [[ $out == "herd $want" ]]; then ok "installed copy reports VERSION"; else bad "installed copy reports VERSION" "$out"; fi

echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
