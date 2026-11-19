#!/usr/bin/env bash
# Runs the "head-guard" lines exactly as .github/workflows/deliver.yml ships them
# (between its BEGIN/END markers) against a fake gh api, and checks which commits
# build and which deploy: the head always ships; an app with staging, or a
# rollback, ships only the head; without staging an older merge pushes its image
# without deploying, and an older release ships unless prod's newest release tag
# descends from it. A release with delivery off never reaches this block (the step before it
# fails the Guard; see pi-deliver-deploy-wiring.sh), so the off case here is staging mode.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$repo_root/.github/workflows/deliver.yml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

awk '/# BEGIN head-guard/{on=1} on{print} /# END head-guard/{on=0}' "$workflow" \
  | sed -E 's/^ {10}//' >"$work/guard.sh"
grep -q 'END head-guard' "$work/guard.sh" || { echo "FAIL: markers not found in $workflow"; exit 1; }

# Fake gh api. HEAD is main's head; TAGS the v* tag names (space separated);
# PROD_SHA what the newest tag resolves to (see below); ON_MAIN and RELATION the compare
# statuses for <sha>...<head> and <prod>...<sha>. A value of "fail" makes that call fail.
cat >"$work/gh" <<'GH'
#!/usr/bin/env bash
shift # api
test "$1" = "--paginate" && shift
path="$1"
reply() { test "$1" = fail && exit 1; printf '%s\n' "$1"; }
case "$path" in
  */git/ref/heads/main) reply "$HEAD" ;;
  */git/matching-refs/tags/v) test "$TAGS" = fail && exit 1; for t in $TAGS; do echo "refs/tags/$t"; done ;;
  # Only the newest tag by version order (v2026.11.15.10) resolves to PROD_SHA. Any other
  # tag resolves to a commit prod has moved past, so picking it skips the release.
  */commits/v2026.11.15.10) reply "$PROD_SHA" ;;
  */commits/*) echo older ;;
  */compare/"$GITHUB_SHA"...*) reply "$ON_MAIN" ;;
  */compare/older...*) echo behind ;;
  */compare/*) reply "$RELATION" ;;
  *) echo "unexpected gh api $path" >&2; exit 2 ;;
esac
GH
chmod +x "$work/gh"

pass=0 fail=0
# name, MODE, HAS_STAGING, DIGEST, HEAD, TAGS, PROD_SHA, ON_MAIN, RELATION, expected "stale=.. build=.." or "error"
run_case() {
  local got out="$work/out" summary="$work/summary"
  : >"$out"; : >"$summary"
  if PATH="$work:$PATH" GITHUB_OUTPUT="$out" GITHUB_STEP_SUMMARY="$summary" GUARD_RETRY_SECONDS=0 \
    GITHUB_REPOSITORY=org/app GITHUB_SHA=aaa DEPLOY_ENABLED="${ENABLED:-true}" \
    MODE="$2" HAS_STAGING="$3" DIGEST="$4" HEAD="$5" TAGS="$6" PROD_SHA="$7" ON_MAIN="$8" RELATION="$9" \
    bash -euo pipefail "$work/guard.sh" >/dev/null 2>&1; then
    got="$(sed -n 's/^stale=//p' "$out" | tail -n 1) $(sed -n 's/^build=//p' "$out" | tail -n 1)"
    got="stale=${got% *} build=${got#* }"
  else
    got=error
  fi
  if test "$got" = "${10}"; then
    pass=$((pass + 1)); echo "ok   $1"
  else
    fail=$((fail + 1)); echo "FAIL $1: got '$got', want '${10}'"
  fi
}

tags="v2026.11.14.9 v2026.11.15.10 v2026.11.15.2 v1.0"
ENABLED=false run_case "delivery off, staging mode: nothing runs" staging false "" aaa "$tags" ppp ahead ahead "stale=true build=false"
run_case "head, staging mode, no staging services" staging false "" aaa "$tags" ppp ahead ahead "stale=false build=true"
run_case "head, release" release false "" aaa "$tags" ppp ahead ahead "stale=false build=true"
run_case "head, rollback" release false "sha256:x" aaa "$tags" ppp ahead ahead "stale=false build=true"
run_case "old merge, app with staging: skipped" staging true "" bbb "$tags" ppp ahead ahead "stale=true build=false"
run_case "old release, app with staging: skipped" release true "" bbb "$tags" ppp ahead ahead "stale=true build=false"
run_case "old rollback: skipped" release false "sha256:x" bbb "$tags" ppp ahead ahead "stale=true build=false"
run_case "old merge, no staging: image only" staging false "" bbb "$tags" ppp ahead ahead "stale=true build=true"
run_case "old release, prod behind it: ships" release false "" bbb "$tags" ppp ahead ahead "stale=false build=true"
run_case "old release, prod on it (retry): ships" release false "" bbb "$tags" ppp ahead identical "stale=false build=true"
run_case "old release, prod ahead of it: skipped" release false "" bbb "$tags" ppp ahead behind "stale=true build=false"
run_case "old release, diverged from prod: error" release false "" bbb "$tags" ppp ahead diverged "error"
run_case "old release, not on main: skipped" release false "" bbb "$tags" ppp diverged ahead "stale=true build=false"
run_case "old release, main unreadable: error" release false "" bbb "$tags" ppp fail ahead "error"
run_case "head unreadable: error" release false "" fail "$tags" ppp ahead ahead "error"
run_case "no release tag: ships" release false "" bbb "v1.0" ppp ahead behind "stale=false build=true"
run_case "tags unreadable: ships" release false "" bbb fail ppp ahead behind "stale=false build=true"
run_case "tag commit unreadable: ships" release false "" bbb "$tags" fail ahead behind "stale=false build=true"
run_case "prod compare unreadable: ships" release false "" bbb "$tags" ppp ahead fail "stale=false build=true"

echo "${pass} passed, ${fail} failed"
test "$fail" -eq 0
