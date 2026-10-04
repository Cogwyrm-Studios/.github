#!/usr/bin/env bash
# Checks the versions locked in a Cargo.lock against the published security
# advisories of a GitHub repository (GHSA published by the maintainers).
#
# Why: cargo-deny only reads the RustSec database, and some upstreams publish
# GHSA advisories that never reach RustSec or the global GitHub Advisory
# Database (quinn-rs/quinn, orrery#49-D2).
#
# Usage: check.sh <Cargo.lock> <owner/repo> <crate>...
#   GH_TOKEN  optional token for the GitHub API. If the API refuses it, the
#             request is repeated without authentication.
#
# Exit codes: 0 no locked version is affected (or none of the crates is in
# the lockfile, in which case the API is not called); 1 at least one locked
# version is affected; 2 error (API, unparsable range or version). Anything
# ambiguous fails; it never passes by default.
#
# Only bash, curl, awk and jq (1.7 or newer), all present on ubuntu-24.04.
set -euo pipefail

API="${GITHUB_API_URL:-https://api.github.com}"

die() {
  echo "::error::$1" >&2
  exit 2
}

[ "$#" -ge 3 ] || die "usage: check.sh <Cargo.lock> <owner/repo> <crate>..."
lockfile="$1"
repo="$2"
shift 2
[ -f "$lockfile" ] || die "$lockfile not found."
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "Invalid repository: $repo"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# name<TAB>version of every package of the lockfile with one of the names.
awk -v names="$*" '
  BEGIN { n = split(names, list, " "); for (i = 1; i <= n; i++) want[list[i]] = 1 }
  function flush() { if (name in want && version != "") print name "\t" version; name = ""; version = "" }
  /^\[\[package\]\]/ { flush(); next }
  /^\[/ { flush(); next }
  /^name = "/ { name = $3; gsub(/"/, "", name) }
  /^version = "/ { version = $3; gsub(/"/, "", version) }
  END { flush() }
' "$lockfile" | sort -u > "$work/locked.tsv"

if [ ! -s "$work/locked.tsv" ]; then
  echo "::notice::None of $* is in $lockfile; $repo advisories not checked."
  exit 0
fi
echo "Locked versions:"
sed 's/\t/ /; s/^/  /' "$work/locked.tsv"

# All published advisories, following the cursor of the Link header.
fetch() {
  local url="$API/repos/$repo/security-advisories?state=published&per_page=100"
  local use_token=""
  [ -n "${GH_TOKEN:-}" ] && use_token=1
  local page=0 status next
  : > "$work/advisories.jsonl"
  while [ -n "$url" ]; do
    page=$((page + 1))
    [ "$page" -le 50 ] || die "More than 50 pages of advisories from $repo; refusing to continue."
    local args=(-sS --retry 3 --retry-all-errors -o "$work/body.json" -D "$work/headers.txt"
      -w '%{http_code}' -H 'Accept: application/vnd.github+json'
      -H 'X-GitHub-Api-Version: 2022-11-28')
    if [ -n "$use_token" ]; then
      status="$(curl "${args[@]}" -H "Authorization: Bearer $GH_TOKEN" "$url")" || status=000
      if [ "$status" = 401 ] || [ "$status" = 403 ] || [ "$status" = 404 ]; then
        echo "::warning::The GitHub API answered $status with the token; retrying without authentication."
        use_token=""
        status="$(curl "${args[@]}" "$url")" || status=000
      fi
    else
      status="$(curl "${args[@]}" "$url")" || status=000
    fi
    [ "$status" = 200 ] || die "Could not read the security advisories of $repo (HTTP $status)."
    jq -e 'type == "array"' "$work/body.json" > /dev/null \
      || die "Unexpected answer for the security advisories of $repo."
    jq -c '.[]' "$work/body.json" >> "$work/advisories.jsonl"
    next="$(tr -d '\r' < "$work/headers.txt" \
      | sed -n 's/^[Ll]ink:.*<\([^>]*\)>; *rel="next".*/\1/p' | head -n 1)"
    url="$next"
  done
}
fetch
echo "Published advisories of $repo: $(wc -l < "$work/advisories.jsonl")"

# Range semantics. The ranges are free text typed by the maintainers, so the
# parser accepts the forms seen in practice and refuses anything else:
#   ">= 0.11.0, <= 0.11.18"   comma joins constraints (GHSA syntax, AND)
#   "0.11.17" / "= 0.11.13"   exact version
#   "0.11.0 - 0.11.6"         inclusive range
#   "< 0.5.16, >= 0.6.0 < 0.6.3"
#                             AND is empty, so the comma groups are read as
#                             alternatives (OR), which is what was meant
# patched_versions lists the first fixed version of each release line
# ("0.11.17", ">= 0.11.19", "0.9.5, 0.10.5"). A locked version is patched when
# it is at or above the fix of its own semver-compatible line, or at or above
# every listed fix. Affected = inside the range and not patched, so a range
# that forgets its upper bound ("> 0.7.0") does not flag fixed versions.
jq -n -r --rawfile locked "$work/locked.tsv" --arg repo "$repo" '
  def trim: gsub("^\\s+|\\s+$"; "");
  # [major, minor, patch, release]: a pre-release sorts before its release.
  def ver:
    (capture("^v?(?<a>[0-9]+)(\\.(?<b>[0-9]+))?(\\.(?<c>[0-9]+))?(-(?<pre>[0-9A-Za-z.-]+))?(\\+[0-9A-Za-z.-]+)?$")
      // error("unparsable version \"\(.)\""))
    | [(.a | tonumber), ((.b // "0") | tonumber), ((.c // "0") | tonumber), (if .pre then 0 else 1 end)];
  def line: if .[0] > 0 then [.[0]] elif .[1] > 0 then [0, .[1]] else [0, 0, .[2]] end;
  def ok($v):
    if .op == ">=" then $v >= .v elif .op == ">" then $v > .v
    elif .op == "<=" then $v <= .v elif .op == "<" then $v < .v
    else $v == .v end;
  def all_ok($v): all(.[]; ok($v));
  # Constraints of one comma group.
  def group:
    . as $text
    | gsub("(?<x>v?[0-9][0-9A-Za-z.+]*)\\s+-\\s+(?<y>v?[0-9])"; ">= \(.x) <= \(.y)")
    | if gsub("(>=|<=|==|>|<|=)?\\s*v?[0-9][0-9A-Za-z.+-]*"; "") | test("^\\s*$") | not
      then error("unparsable range \"\($text)\"") else . end
    | [scan("(>=|<=|==|>|<|=)?\\s*(v?[0-9][0-9A-Za-z.+-]*)")
       | {op: ((.[0] // "=") | if . == "==" then "=" else . end), v: (.[1] | ver)}];
  # Whether some version satisfies every constraint. The order is discrete,
  # so a non-empty interval always holds one of these candidates.
  def satisfiable:
    . as $cs
    | ([[0, 0, 0, 0], [1000000000, 0, 0, 1]]
       + [$cs[].v | ., [.[0], .[1], .[2], 1], [.[0], .[1], .[2] + 1, 0]])
    | any(.[]; . as $v | $cs | all_ok($v));
  def in_range($v):
    if . == null or (trim == "") then true
    else [split(",")[] | trim | select(. != "") | group] as $groups
      | if $groups == [] then error("empty range") else . end
      | ($groups | add) as $all
      | if ($all | satisfiable) then ($all | all_ok($v))
        else any($groups[]; all_ok($v)) end
    end;
  def patched($v):
    if . == null or (trim == "") then false
    else [split(",")[] | trim | select(. != "")
          | (capture("^(>=)?\\s*(?<x>v?[0-9][0-9A-Za-z.+-]*)$")
             // error("unparsable patched version \"\(.)\"")) | .x | ver] as $fixes
      | any($fixes[]; (line == ($v | line)) and $v >= .) or ($v >= ($fixes | max))
    end;

  [$locked | split("\n")[] | select(. != "") | split("\t") | {name: .[0], version: .[1]}] as $pkgs
  | [inputs] as $advisories
  | [ $advisories[] | select(.withdrawn_at == null) as $a
      | $a.vulnerabilities[]?
      | select((.package.ecosystem // "" | ascii_downcase) == "rust") as $vuln
      | $pkgs[] | select(.name == $vuln.package.name) as $pkg
      | try (
          ($pkg.version | ver) as $v
          | if ($vuln.vulnerable_version_range | in_range($v))
               and (($vuln.patched_versions | patched($v)) | not)
            then ["AFFECTED", "\($pkg.name) \($pkg.version) is affected by \($a.ghsa_id) (\($a.severity // "unknown")): \($a.summary). Vulnerable: \($vuln.vulnerable_version_range // "all"); patched: \($vuln.patched_versions // "none"). \($a.html_url)"]
            else empty end
        ) catch ["ERROR", "\($a.ghsa_id) for \($pkg.name) \($pkg.version): \(.)"]
    ]
  | .[]
  | "\(.[0])\t\(.[1] | gsub("[\\t\\r\\n]+"; " "))"
' "$work/advisories.jsonl" > "$work/findings.tsv" || die "Could not evaluate the advisories of $repo."

status=0
while IFS=$'\t' read -r kind message; do
  case "$kind" in
    AFFECTED)
      echo "::error::$message"
      [ "$status" -eq 2 ] || status=1
      ;;
    ERROR)
      echo "::error::Cannot evaluate $message. Fix the parser or review by hand."
      status=2
      ;;
  esac
done < "$work/findings.tsv"

if [ "$status" -eq 0 ]; then
  echo "No locked version is affected by a published advisory of $repo."
fi
exit "$status"
