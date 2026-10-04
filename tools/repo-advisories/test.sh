#!/usr/bin/env bash
# Tests of check.sh against a fake GitHub API (python3 -m http.server, which
# ignores the query string). Each case: name, locked "crate=version ...",
# advisories (JSON array; empty for a 404), exceptions (JSON or empty),
# expected exit code, expected text in the output, optional minimum count.
#
# Usage: tools/repo-advisories/test.sh   (needs bash, curl, jq, python3)
set -u
T="$(cd "$(dirname "$0")" && pwd)/check.sh"
W="$(mktemp -d)"
mkdir -p "$W/srv"
PORT="${TEST_PORT:-8799}"
(cd "$W/srv" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 > /dev/null 2>&1) &
SRV=$!
trap 'kill "$SRV"; rm -rf "$W"' EXIT
for _ in $(seq 50); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/" && break
  sleep 0.1
done
FUT=$(date -u -d '+30 days' +%F); PAST=$(date -u -d '-1 day' +%F)
adv() { # id range patched [ecosystem] [crate]
  jq -nc --arg id "$1" --arg r "$2" --arg p "$3" --arg e "${4-rust}" --arg c "${5-quinn-proto}" \
    '{ghsa_id:$id,severity:"high",summary:"s",html_url:"u",withdrawn_at:null,
      vulnerabilities:[{package:{ecosystem:$e,name:$c},vulnerable_version_range:(if $r=="NULL" then null else $r end),patched_versions:(if $p=="NULL" then null else $p end)}]}'
}
pass=0
fail=0
check() { # name lock advisories-json-array exceptions expected-exit substring [min]
  local name=$1 lock=$2 advs=$3 exc=$4 want=$5 sub=$6 min=${7-1}
  if [ -n "$advs" ]; then mkdir -p "$W/srv/repos/t/$name"; echo "$advs" > "$W/srv/repos/t/$name/security-advisories"; fi
  { echo 'version = 4'; for p in $lock; do printf '\n[[package]]\nname = "%s"\nversion = "%s"\n' "${p%%=*}" "${p#*=}"; done; } > "$W/$name.lock"
  local exargs=()
  if [ -n "$exc" ]; then echo "$exc" > "$W/$name.exc.json"; exargs=(--exceptions "$W/$name.exc.json"); fi
  out=$(GITHUB_API_URL=http://127.0.0.1:$PORT "$T" --lock "$W/$name.lock" --repo "t/$name" --min-advisories "$min" "${exargs[@]}" quinn quinn-proto quinn-udp 2>&1); got=$?
  if [ "$got" = "$want" ] && grep -qF -- "$sub" <<< "$out"; then pass=$((pass+1)); echo "ok   $name (exit $got)"
  else fail=$((fail+1)); echo "FAIL $name: exit $got want $want, missing '$sub'"; printf '%s\n' "$out"; fi
}
A465=$(adv GHSA-465w-v9q3-7j98 '> 0.7.0' '>= 0.11.18')
EX() { echo "{\"exceptions\":[$1]}"; }
E465="{\"advisory\":\"GHSA-465w-v9q3-7j98\",\"crate\":\"quinn-proto\",\"version\":\"0.12.0\",\"reason\":\"quinn 0.12 rewrote the code path; checked upstream\",\"review-by\":\"$FUT\"}"

# 1. Below the fix of its own line, outside the range (GHSA-q8wc).
check q8wc-0.10.3 "quinn-proto=0.10.3" "[$(adv GHSA-q8wc-j5m9-27w3 '< 0.9.5' '0.9.5, 0.10.5')]" "" 1 "below the fix 0.10.5"
check q8wc-0.10.5 "quinn-proto=0.10.5" "[$(adv GHSA-q8wc-j5m9-27w3 '< 0.9.5' '0.9.5, 0.10.5')]" "" 0 "No locked version"
check q8wc-0.9.4 "quinn-proto=0.9.4" "[$(adv GHSA-q8wc-j5m9-27w3 '< 0.9.5' '0.9.5, 0.10.5')]" "" 1 "below the fix 0.9.5"
# 2. Inside the range, no fix for its line: unresolved; exceptions.
check open-0.12 "quinn-proto=0.12.0" "[$A465]" "" 2 "no fix is listed for its line"
check open-0.11.19 "quinn-proto=0.11.19" "[$A465]" "" 0 "No locked version"
check exc-ok "quinn-proto=0.12.0" "[$A465]" "$(EX "$E465")" 0 "accepted by the exception"
check exc-expired "quinn-proto=0.12.0" "[$A465]" "$(EX "${E465/$FUT/$PAST}")" 2 "Expired exception"
check exc-unused "quinn-proto=0.11.19" "[$A465]" "$(EX "$E465")" 2 "Unused exception"
check exc-other-version "quinn-proto=0.12.1" "[$A465]" "$(EX "$E465")" 2 "Unused exception"
check exc-no-reason "quinn-proto=0.12.0" "[$A465]" "$(EX "${E465/quinn 0.12 rewrote the code path; checked upstream/}")" 2 "needs a \"reason\""
check exc-bad-date "quinn-proto=0.12.0" "[$A465]" "$(EX "${E465/$FUT/2026-02-30}")" 2 "valid YYYY-MM-DD"
check exc-dup "quinn-proto=0.12.0" "[$A465]" "$(EX "$E465,$E465")" 2 "Duplicate exception"
check exc-half "quinn-proto=0.12.0" "[$A465]" "$(EX "{\"advisory\":\"GHSA-465w-v9q3-7j98\",\"crate\":\"quinn-proto\",\"reason\":\"some long reason\",\"review-by\":\"$FUT\"}")" 2 "both \"crate\" and \"version\""
check exc-extra-key "quinn-proto=0.12.0" "[$A465]" "$(EX "${E465%\}},\"ranges\":\"*\"}")" 2 "unknown keys"
check exc-bad-file "quinn-proto=0.12.0" "[$A465]" "{\"exceptions\":[],\"x\":1}" 2 "nothing else"
check no-fix "quinn-proto=0.11.19" "[$(adv GHSA-2222-3333-4444 '>= 0.11.0' NULL)]" "" 1 "no fix published"
check no-range "quinn-proto=0.11.19" "[$(adv GHSA-2222-3333-4444 NULL NULL)]" "" 1 "no fix published"
# 3. Pre-releases in ranges and fixes.
check pre-range "quinn-proto=0.11.3" "[$(adv GHSA-2222-3333-4444 '0.11.0-0.11.6' '0.11.7')]" "" 2 "pre-release or build metadata"
check pre-fix "quinn-proto=0.11.3" "[$(adv GHSA-2222-3333-4444 '< 0.11.7' '0.11.7-rc.1')]" "" 2 "pre-release or build metadata"
check build-range "quinn-proto=0.11.3" "[$(adv GHSA-2222-3333-4444 '< 0.11.7+x' '0.11.7')]" "" 2 "pre-release or build metadata"
check hyphen-ok "quinn-proto=0.11.3" "[$(adv GHSA-2222-3333-4444 '0.11.0 - 0.11.6' '0.11.7')]" "" 1 "below the fix 0.11.7"
# 4. Partial versions.
check partial-eq "quinn-proto=0.11.3" "[$(adv GHSA-2222-3333-4444 '= 0.11' '0.12.0')]" "" 2 "partial version"
check partial-bare "quinn-proto=0.11.3" "[$(adv GHSA-2222-3333-4444 '0.11' '0.12.0')]" "" 2 "partial version"
check partial-le "quinn-proto=0.11.3" "[$(adv GHSA-2222-3333-4444 '<= 0.11' '0.12.0')]" "" 2 "partial version"
check partial-gt "quinn-proto=0.11.3" "[$(adv GHSA-2222-3333-4444 '> 0.10' '0.12.0')]" "" 2 "partial version"
check partial-fix "quinn-proto=0.11.3" "[$(adv GHSA-2222-3333-4444 '< 0.12.0' '0.12')]" "" 2 "partial version"
check partial-lt "quinn-proto=0.11.3" "[$(adv GHSA-2222-3333-4444 '>= 0.11, < 0.12' '>= 0.12')]" "" 2 "no fix is listed for its line"
check caret "quinn-proto=0.11.3" "[$(adv GHSA-2222-3333-4444 '^0.11' '0.12.0')]" "" 2 "unparsable range"
# 5. Advisories without a usable Rust entry, and the minimum count.
check vulns-empty "quinn-proto=0.11.19" '[{"ghsa_id":"GHSA-2222-3333-4444","withdrawn_at":null,"vulnerabilities":[]}]' "" 2 "no vulnerable package"
check vulns-null "quinn-proto=0.11.19" '[{"ghsa_id":"GHSA-2222-3333-4444","withdrawn_at":null,"vulnerabilities":null}]' "" 2 "no vulnerable package"
check eco-null "quinn-proto=0.11.19" '[{"ghsa_id":"GHSA-2222-3333-4444","withdrawn_at":null,"vulnerabilities":[{"package":{"ecosystem":null,"name":"quinn-proto"}}]}]' "" 2 "not a Rust crate"
check eco-case "quinn-proto=0.11.19" "[$(adv GHSA-2222-3333-4444 '< 0.11.20' '0.11.20' Rust)]" "" 2 "not a Rust crate"
check eco-npm "quinn-proto=0.11.19" "[$(adv GHSA-2222-3333-4444 '< 0.11.20' '0.11.20' npm)]" "" 2 "not a Rust crate"
check eco-mixed "quinn-proto=0.11.19" '[{"ghsa_id":"GHSA-2222-3333-4444","withdrawn_at":null,"vulnerabilities":[{"package":{"ecosystem":"rust","name":"quinn-proto"},"vulnerable_version_range":"< 0.11.0","patched_versions":"0.11.0"},{"package":{"ecosystem":"pip","name":"aioquic"}}]}]' "" 2 "not a Rust crate"
check exc-advisory-level "quinn-proto=0.11.19" "[$(adv GHSA-2222-3333-4444 '< 0.11.20' '0.11.20' npm)]" "$(EX "{\"advisory\":\"GHSA-2222-3333-4444\",\"reason\":\"npm binding only, not a Rust crate\",\"review-by\":\"$FUT\"}")" 0 "accepted by the exception"
check min-count "quinn-proto=0.11.19" "[$A465]" "" 2 "fewer than the 13 known" 13
check withdrawn "quinn-proto=0.11.3" '[{"ghsa_id":"GHSA-2222-3333-4444","withdrawn_at":"2026-01-01T00:00:00Z","vulnerabilities":[]}]' "" 0 "No locked version"
check api-404 "quinn-proto=0.11.3" "" "" 2 "HTTP 404"
check no-crates "serde=1.0.0" "[$A465]" "" 0 "advisories not checked"
check no-crates-exc "serde=1.0.0" "[$A465]" "$(EX "$E465")" 2 "has exceptions"
echo "passed=$pass failed=$fail"
[ "$fail" = 0 ]
