#!/usr/bin/env bash
# Checks the versions locked in a Cargo.lock against the security advisories
# that a GitHub repository publishes itself (repository GHSA).
#
# Why: cargo-deny only reads the RustSec database, and some upstreams publish
# advisories that never reach RustSec or the global GitHub Advisory Database
# (quinn-rs/quinn, orrery#49-D2).
#
# Usage:
#   check.sh --lock <Cargo.lock> --repo <owner/repo> --min-advisories <n>
#            [--exceptions <advisory-exceptions.json>] <crate>...
#
#   GH_TOKEN  optional token for the GitHub API. If the API refuses it (401,
#             403 or 404), the request is repeated without authentication.
#
# Exit codes:
#   0  no locked version is affected, or none of the crates is in the
#      lockfile (then the API is not called);
#   1  a locked version is affected;
#   2  the answer cannot be trusted: API failure, fewer advisories than
#      --min-advisories, an advisory without a usable Rust entry, a range or
#      fix the parser refuses, a version inside the range with no fix for its
#      own release line, or an invalid, expired or unused exception.
# Every finding except API, count and file errors can be accepted by a
# reviewed exception (see README.md). Nothing ambiguous passes by default.
#
# Only bash, curl, awk, date and jq (1.7 or newer), all on ubuntu-24.04.
set -euo pipefail

API="${GITHUB_API_URL:-https://api.github.com}"

die() {
  echo "::error::$1" >&2
  exit 2
}

lockfile=""
repo=""
min_advisories=""
exceptions_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --lock) lockfile="${2:-}"; shift 2 ;;
    --repo) repo="${2:-}"; shift 2 ;;
    --min-advisories) min_advisories="${2:-}"; shift 2 ;;
    --exceptions) exceptions_file="${2:-}"; shift 2 ;;
    --) shift; break ;;
    -*) die "Unknown option: $1" ;;
    *) break ;;
  esac
done
[ "$#" -ge 1 ] && [ -n "$lockfile" ] && [ -n "$repo" ] && [ -n "$min_advisories" ] \
  || die "usage: check.sh --lock <Cargo.lock> --repo <owner/repo> --min-advisories <n> [--exceptions <file>] <crate>..."
[ -f "$lockfile" ] || die "$lockfile not found."
[[ "$repo" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "Invalid repository: $repo"
[[ "$min_advisories" =~ ^[0-9]+$ ]] || die "Invalid --min-advisories: $min_advisories"
for crate in "$@"; do
  [[ "$crate" =~ ^[A-Za-z0-9_-]+$ ]] || die "Invalid crate name: $crate"
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Exceptions of the consumer repository. A missing file means no exception.
if [ -n "$exceptions_file" ] && [ -f "$exceptions_file" ]; then
  jq -e 'type == "object"' "$exceptions_file" > /dev/null 2>&1 \
    || die "$exceptions_file is not a JSON object."
  cp "$exceptions_file" "$work/exceptions.json"
else
  echo '{"exceptions": []}' > "$work/exceptions.json"
fi

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
  if [ "$(jq '.exceptions | length? // 0' "$work/exceptions.json")" != 0 ]; then
    die "None of $* is in $lockfile, but $exceptions_file has exceptions. Remove them."
  fi
  echo "::notice::None of $* is in $lockfile; $repo advisories not checked."
  exit 0
fi
echo "Locked versions:"
sed 's/\t/ /; s/^/  /' "$work/locked.tsv"

# Every published advisory (withdrawn ones included), following the cursor
# of the Link header.
fetch() {
  local url="$API/repos/$repo/security-advisories?state=published&per_page=100"
  local use_token=""
  [ -n "${GH_TOKEN:-}" ] && use_token=1
  local page=0 status
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
    jq -e 'type == "array"' "$work/body.json" > /dev/null 2>&1 \
      || die "Unexpected answer for the security advisories of $repo."
    jq -c '.[]' "$work/body.json" >> "$work/advisories.jsonl"
    url="$(tr -d '\r' < "$work/headers.txt" \
      | sed -n 's/^[Ll]ink:.*<\([^>]*\)>; *rel="next".*/\1/p' | head -n 1)"
  done
}
fetch
count="$(wc -l < "$work/advisories.jsonl")"
echo "Published advisories of $repo: $count"
# Advisories are never deleted, only withdrawn, so fewer than the known
# number means a broken answer (or a token that sees less), not good news.
[ "$count" -ge "$min_advisories" ] \
  || die "Only $count published advisories from $repo, fewer than the $min_advisories known. Refusing to trust the answer."

# Rules (README.md, "Avisos de segurança do quinn"):
# - Ranges and fixes are free text typed by the maintainers. Accepted forms:
#   ">= 0.11.0, <= 0.11.18" (comma = AND), "0.11.17" or "= 0.11.13" (exact),
#   "0.11.0 - 0.11.6" (inclusive). When the AND of every comma group is empty
#   ("< 0.5.16, >= 0.6.0 < 0.6.3"), the groups are alternatives (OR).
#   Pre-releases and build metadata are refused. A partial version is padded
#   with zeros only after "<" or ">=", where padding is exact; anywhere else
#   ("= 0.11", "0.11", "<= 0.11", "> 0.11") it is refused.
# - patched_versions lists the first fixed version of each release line
#   (semver-compatible: same major, or same minor under 0.x).
# - A locked version is AFFECTED when it is inside the range, or below the
#   fix listed for its own line. It is clean when it is at or above the fix
#   of its own line, or outside the range with no fix for its line. Inside
#   the range with fixes listed only for other lines it is UNRESOLVED: a new
#   line (say 0.12) under an open range ("> 0.7.0") needs a reviewed
#   exception, because the advisory does not say whether it is fixed. At or
#   above the fix of its own line but inside a range with an upper bound is
#   contradictory data, an ERROR.
# - An advisory with an unusable entry gives one advisory-level ERROR; its
#   usable Rust entries are still evaluated.
jq -n -r \
  --rawfile locked "$work/locked.tsv" \
  --slurpfile exfile "$work/exceptions.json" \
  --arg today "$(date -u +%Y-%m-%d)" \
  --arg latest "$(date -u -d '+90 days' +%Y-%m-%d)" \
  --arg repo "$repo" '
  def trim: gsub("^\\s+|\\s+$"; "");
  # Locked version: [major, minor, patch, release]; a pre-release sorts
  # before its release.
  def lver:
    (capture("^(?<a>[0-9]+)\\.(?<b>[0-9]+)\\.(?<c>[0-9]+)(-(?<pre>[0-9A-Za-z.-]+))?(\\+[0-9A-Za-z.-]+)?$")
      // error("unparsable locked version \"\(.)\""))
    | [(.a | tonumber), (.b | tonumber), (.c | tonumber), (if .pre then 0 else 1 end)];
  # Version of a range or fix, after the operator $op.
  def cver($op):
    . as $text
    | if test("[-+]") then error("pre-release or build metadata in \"\($text)\" is not supported") else . end
    | (capture("^v?(?<a>[0-9]+)(\\.(?<b>[0-9]+))?(\\.(?<c>[0-9]+))?$")
        // error("unparsable version \"\($text)\""))
    | if (.c == null) and ($op != "<" and $op != ">=")
      then error("partial version \"\($text)\" after \"\(if $op == "=" then "= or no operator" else $op end)\" is ambiguous")
      else . end
    | [(.a | tonumber), ((.b // "0") | tonumber), ((.c // "0") | tonumber), 1];
  def line: if .[0] > 0 then [.[0]] elif .[1] > 0 then [0, .[1]] else [0, 0, .[2]] end;
  def show: "\(.[0]).\(.[1]).\(.[2])";
  def ok($v):
    if .op == ">=" then $v >= .v elif .op == ">" then $v > .v
    elif .op == "<=" then $v <= .v elif .op == "<" then $v < .v
    else $v == .v end;
  def all_ok($v): all(.[]; ok($v));
  # Constraints of one comma group. Tokens are taken greedily, so anything
  # odd ends up inside a version and is refused by cver.
  def group:
    . as $text
    | gsub("(?<x>v?[0-9][0-9A-Za-z.+]*)\\s+-\\s+(?<y>v?[0-9])"; ">= \(.x) <= \(.y)")
    | if gsub("(>=|<=|==|>|<|=)?\\s*v?[0-9][0-9A-Za-z.+-]*"; "") | test("^\\s*$") | not
      then error("unparsable range \"\($text)\"") else . end
    | [scan("(>=|<=|==|>|<|=)?\\s*(v?[0-9][0-9A-Za-z.+-]*)")
       | ((.[0] // "=") | if . == "==" then "=" else . end) as $op
       | {op: $op, v: (.[1] | cver($op))}];
  # Whether some version satisfies every constraint. The order is discrete,
  # so a non-empty interval always holds one of these candidates.
  def satisfiable:
    . as $cs
    | ([[0, 0, 0, 0], [1000000000, 0, 0, 1]]
       + [$cs[].v | ., [.[0], .[1], .[2], 1], [.[0], .[1], .[2] + 1, 0]])
    | any(.[]; . as $v | $cs | all_ok($v));
  def bounded: any(.[]; .op == "<" or .op == "<=" or .op == "=");
  # {in, bounded}: whether $v is inside the range, and whether the
  # constraints that put it there have an upper bound.
  def range_hit($v):
    if . == null or (trim == "") then {in: true, bounded: false}
    else [split(",")[] | trim | select(. != "") | group] as $groups
      | if $groups == [] then error("empty range") else . end
      | ($groups | add) as $all
      | if ($all | satisfiable) then {in: ($all | all_ok($v)), bounded: ($all | bounded)}
        else [$groups[] | select(all_ok($v))] as $hits
          | {in: ($hits != []), bounded: any($hits[]; bounded)}
        end
    end;
  def fixes:
    if . == null or (trim == "") then []
    else [split(",")[] | trim | select(. != "")
          | (capture("^(?<op>>=)?\\s*(?<x>\\S+)$") // error("unparsable fix \"\(.)\""))
          | (if .op then ">=" else "=" end) as $op | .x | cver($op)]
    end;
  def usable: (.package | type) == "object" and .package.ecosystem == "rust"
    and (.package.name | type) == "string" and .package.name != "";
  def key($a; $c; $v; $k): {advisory: $a, crate: $c, version: $v, kind: $k};
  def showkey: "\(.advisory) \(.kind)\(if .crate then " \(.crate) \(.version)" else " (whole advisory)" end)";

  [$locked | split("\n")[] | select(. != "") | split("\t") | {name: .[0], version: .[1]}] as $pkgs
  | [inputs | select(.withdrawn_at == null)] as $advisories

  # Findings: {key, kind, message}; the kind is part of the key.
  | [ $advisories[] | . as $a | ($a.ghsa_id // "advisory without ghsa_id") as $id
      | (if ($a.vulnerabilities | type) != "array" then [] else $a.vulnerabilities end) as $vulns
      | ( if $vulns == [] then
            {key: key($id; null; null; "ERROR"), kind: "ERROR",
             message: "\($id) has no vulnerable package listed. \($a.html_url // "")"}
          elif any($vulns[]; usable | not) then
            {key: key($id; null; null; "ERROR"), kind: "ERROR",
             message: "\($id) lists a package that is not a Rust crate (ecosystem must be \"rust\"): \([$vulns[] | select(usable | not) | "\(.package.ecosystem? // "null"):\(.package.name? // "null")"] | join(", ")). \($a.html_url // "")"}
          else empty end ),
        # The usable Rust entries are always evaluated, even when the
        # advisory also has an unusable entry.
        ( $vulns[] | select(usable) as $vuln
          | $pkgs[] | select(.name == $vuln.package.name) as $pkg
          | try (
              ($pkg.version | lver) as $v
              | ($vuln.vulnerable_version_range | range_hit($v)) as $hit
              | ($vuln.patched_versions | fixes) as $fixes
              | [$fixes[] | select(line == ($v | line))] as $own
              | "\($pkg.name) \($pkg.version), \($id) (\($a.severity // "unknown")): \($a.summary // ""). Vulnerable: \($vuln.vulnerable_version_range // "all"); patched: \($vuln.patched_versions // "none"). \($a.html_url // "")" as $about
              | if ($own | length) > 1 then
                  error("several fixes listed for the line of \($pkg.version)")
                elif ($own | length) == 1 then
                  if $v < $own[0] then ["AFFECTED", "Affected (below the fix \($own[0] | show) of its line): \($about)"]
                  elif $hit.in and $hit.bounded then
                    error("contradictory advisory: \($pkg.version) is at or above the fix \($own[0] | show) of its line, but inside a range with an upper bound")
                  else empty end
                elif $hit.in then
                  if $fixes == [] then ["AFFECTED", "Affected (no fix published): \($about)"]
                  else ["UNRESOLVED", "Inside the range, and no fix is listed for its line; needs a reviewed exception or an update: \($about)"] end
                else empty end
            ) catch ["ERROR", "Cannot evaluate \($id) for \($pkg.name) \($pkg.version): \(.)"]
          | {key: key($id; $pkg.name; $pkg.version; .[0]), kind: .[0], message: .[1]} )
    ] as $findings

  # Exceptions: {advisory, kind, crate, version, reason, review-by}; crate
  # and version are both present (one locked package) or both absent (an
  # advisory-level finding). The kind must match the finding, so a finding
  # that changes kind leaves the exception unused.
  | ["advisory", "kind", "crate", "version", "reason", "review-by"] as $allowed
  | ($exfile[0]) as $file
  | (if ($file | has("exceptions") | not) or ($file.exceptions | type) != "array"
         or ($file | keys) != ["exceptions"]
     then [{bad: "the file must be {\"exceptions\": [...]} and nothing else"}]
     else [$file.exceptions | to_entries[] | .key as $i | .value
       | if type != "object" then {bad: "entry \($i) is not an object"}
         elif (keys - $allowed) != [] then
           {bad: "entry \($i) has unknown keys \(keys - $allowed)"}
         elif ((.advisory | type) != "string") or (.advisory | test("^GHSA(-[23456789cfghjmpqrvwx]{4}){3}$") | not) then
           {bad: "entry \($i) needs \"advisory\": a GHSA id"}
         elif [.kind] | inside(["AFFECTED", "UNRESOLVED", "ERROR"]) | not then
           {bad: "entry \($i) (\(.advisory)) needs \"kind\": AFFECTED, UNRESOLVED or ERROR"}
         elif ((.reason | type) != "string") or ((.reason | trim | length) < 10) then
           {bad: "entry \($i) (\(.advisory)) needs a \"reason\""}
         elif ((has("crate")) != (has("version"))) then
           {bad: "entry \($i) (\(.advisory)) needs both \"crate\" and \"version\", or neither"}
         elif has("crate") and (((.crate | type) != "string") or ((.version | type) != "string")) then
           {bad: "entry \($i) (\(.advisory)): \"crate\" and \"version\" are strings"}
         elif ((."review-by" | type) != "string")
              or ((."review-by" | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")) | not)
              or ((try (."review-by" | strptime("%Y-%m-%d") | mktime | strftime("%Y-%m-%d")) catch "") != ."review-by") then
           {bad: "entry \($i) (\(.advisory)) needs \"review-by\" as a valid YYYY-MM-DD date"}
         elif ."review-by" > $latest then
           {bad: "entry \($i) (\(.advisory)): \"review-by\" \(."review-by") is more than 90 days ahead (latest \($latest))"}
         else
           {key: key(.advisory; .crate; .version; .kind), reason, review: ."review-by",
            expired: (."review-by" < $today)}
         end]
     end) as $exceptions
  | ([$exceptions[] | select(has("key")) | .key] | group_by(.) | map(select(length > 1) | .[0])) as $dups
  | [$exceptions[] | select(has("key") and (.expired | not))] as $valid
  # An exception accepts a finding only when it matches exactly one.
  | [$valid[] | . as $e | select([$findings[] | select(.key == $e.key)] | length == 1)] as $usable

  | ( $findings[]
      | . as $f
      | [$usable[] | select(.key == $f.key)][0] as $ex
      | if $ex then ["EXCEPTED", "\($f.kind) accepted by the exception (\($ex.reason); review by \($ex.review)): \($f.message)"]
        else [$f.kind, $f.message] end
    ),
    ( $exceptions[] | select(has("bad")) | ["BADEXC", "Invalid exception: \(.bad)."] ),
    ( $dups[] | ["BADEXC", "Duplicate exception for \(showkey)."] ),
    ( $exceptions[] | select(has("key") and .expired)
      | ["BADEXC", "Expired exception for \(.key | showkey) (review by \(.review), today is \($today)). Review it again or update the crate."] ),
    ( $valid[] | . as $e | ([$findings[] | select(.key == $e.key)] | length) as $n | select($n != 1)
      | if $n == 0 then ["BADEXC", "Unused exception for \(.key | showkey): no finding of that kind matches it. Remove or update it."]
        else ["BADEXC", "Exception for \(.key | showkey) matches \($n) findings; it must match exactly one."] end )
  | "\(.[0])\t\(.[1] | gsub("[\\t\\r\\n]+"; " "))"
' "$work/advisories.jsonl" > "$work/findings.tsv" || die "Could not evaluate the advisories of $repo."

status=0
while IFS=$'\t' read -r kind message; do
  case "$kind" in
    AFFECTED)
      echo "::error::$message"
      [ "$status" -eq 2 ] || status=1
      ;;
    UNRESOLVED | ERROR | BADEXC)
      echo "::error::$message"
      status=2
      ;;
    EXCEPTED)
      echo "::warning::$message"
      ;;
    *)
      echo "::error::Unexpected output: $kind $message"
      status=2
      ;;
  esac
done < "$work/findings.tsv"

if [ "$status" -eq 0 ]; then
  echo "No locked version is affected by a published advisory of $repo."
fi
exit "$status"
