#!/usr/bin/env bash
# Runs the "rollback-target" lines exactly as .github/workflows/deliver.yml ships
# them (between its BEGIN/END markers) against a fake GitHub releases API, and
# checks that a rollback accepts only a digest listed in a published release,
# takes every image from that release, rolls back only the services that
# release deployed, and refuses everything else.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$repo_root/.github/workflows/deliver.yml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

awk '/# BEGIN rollback-target/{on=1} on{print} /# END rollback-target/{on=0}' "$workflow" \
  | sed -E 's/^ {10}//' >"$work/target.sh"
grep -q 'END rollback-target' "$work/target.sh" || { echo "FAIL: markers not found in $workflow"; exit 1; }

a="sha256:$(printf 'a%.0s' $(seq 64))"
b="sha256:$(printf 'b%.0s' $(seq 64))"
c="sha256:$(printf 'c%.0s' $(seq 64))"
d="sha256:$(printf 'd%.0s' $(seq 64))"
w="sha256:$(printf 'e%.0s' $(seq 64))"
note() { printf 'Images (linux/amd64), deployed by digest:\n- `%s`\n' "$@"; }
# Two pages, as gh api --paginate prints them.
# Release 2 lists its services; release 1 predates the list (it deployed only <app>).
jq -nc --arg a "$(note "app/web@$a")" --arg b "$(note "app/web@$b" "app/worker@$w")"$'\n\nServices: `app`, `app-demo`' '[
  {tag_name: "v2026.11.01.1", draft: false, prerelease: false, published_at: "2026-11-01T01:00:00Z", body: $a},
  {tag_name: "v2026.11.01.2", draft: false, prerelease: false, published_at: "2026-11-01T02:00:00Z", body: $b}]' >"$work/page1.json"
jq -nc --arg c "$(note "app/web@$c")" --arg d "$(note "app/web@$d")" '[
  {tag_name: "v2026.11.01.3", draft: true, prerelease: false, published_at: null, body: $c},
  {tag_name: "v2026.11.01.4", draft: false, prerelease: true, published_at: "2026-11-01T04:00:00Z", body: $d}]' >"$work/page2.json"

pass=0 fail=0
run_case() { # name, digest, images json, expected last line (prefix match), [services json]
  local got
  got="$(DIGEST="$2" IMAGES_INPUT="$3" SERVICES_INPUT="${5:-}" APP=app SOURCE_REPOSITORY=o/app PAGES="$work" bash -euo pipefail -c '
    gh() { cat "$PAGES/page1.json"; echo; cat "$PAGES/page2.json"; }
    . "$1"
    echo "tag=${rollback_tag} pins=${pins} services=${services}"' _ "$work/target.sh" 2>&1 | tail -n 1 || true)"
  if [[ "$got" == "$4"* ]]; then
    pass=$((pass + 1)); echo "ok   $1"
  else
    fail=$((fail + 1)); echo "FAIL $1: got '$got', want '$4...'"
  fi
}

web='[{"name":"web","dockerfile":"Dockerfile","context":"."}]'
both='[{"name":"web","dockerfile":"Dockerfile","context":"."},{"name":"worker","dockerfile":"w.Dockerfile","context":"."}]'

run_case "digest of a published release" "$a" "$web" "tag=v2026.11.01.1 pins={\"app/web\":\"$a\"}"
run_case "multi-image release rolls back as a unit" "$b" "$both" "tag=v2026.11.01.2 pins={\"app/web\":\"$b\",\"app/worker\":\"$w\"}"
run_case "a digest in no release is refused" "sha256:$(printf 'f%.0s' $(seq 64))" "$web" "::error::sha256:"
run_case "a draft release's digest is refused" "$c" "$web" "::error::$c is not in any published release"
run_case "a prerelease's digest is refused" "$d" "$web" "::error::$d is not in any published release"
run_case "a malformed digest is refused" "sha256:abc" "$web" "::error::digest must be sha256:<64 hex>"
run_case "a release missing one of the images is refused" "$a" "$both" "::error::Release v2026.11.01.1 lists no digest for app/worker"
run_case "a worker digest alone selects its release" "$w" "$web" "tag=v2026.11.01.2 pins={\"app/web\":\"$b\"}"
run_case "no services input: the app's own service" "$b" "$web" "tag=v2026.11.01.2 pins={\"app/web\":\"$b\"} services=[\"app\"]"
run_case "a release without a services list rolls back only <app>" "$a" "$web" \
  "tag=v2026.11.01.1 pins={\"app/web\":\"$a\"} services=[\"app\"]" '["app","app-demo"]'
run_case "only the services the release listed" "$b" "$web" \
  "tag=v2026.11.01.2 pins={\"app/web\":\"$b\"} services=[\"app\",\"app-demo\"]" '["app","app-demo","app-new"]'
run_case "a release that deployed none of the current services is refused" "$a" "$web" \
  "::error::Release v2026.11.01.1 deployed none of the current services" '["app-demo"]'

echo "${pass} passed, ${fail} failed"
test "$fail" -eq 0
