#!/usr/bin/env bash
# Runs the "lock-recheck" lines exactly as .github/workflows/deliver.yml ships
# them (between its BEGIN/END markers) against fake aws and gh commands, and
# checks when a deploy that waited for the environment lock still deploys: it
# skips when any service already runs a descendant of this commit, stops when a
# service runs a commit off this history, and deploys when the running commit
# cannot be resolved.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$repo_root/.github/workflows/deliver.yml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

awk '/# BEGIN lock-recheck/{on=1} on{print} /# END lock-recheck/{on=0}' "$workflow" \
  | sed -E 's/^ {10}//' >"$work/recheck.sh"
grep -q 'END lock-recheck' "$work/recheck.sh" || { echo "FAIL: markers not found in $workflow"; exit 1; }

# Fake aws. RELEASES maps services to the SENTRY_RELEASE their live revision
# holds ("svc=value svc2=value"); "none" means no SENTRY_RELEASE, "fail" an
# unreadable service.
cat >"$work/aws" <<'AWS'
#!/usr/bin/env bash
args="$*"
lookup() { for pair in $RELEASES; do test "${pair%%=*}" = "$1" && { echo "${pair#*=}"; return; }; done; echo fail; }
case "$args" in
  "ecs describe-services "*)
    family="$(sed -E 's/.*--services ([^ ]+).*/\1/' <<<"$args")"; svc="${family%-*}"
    test "$(lookup "$svc")" = fail && exit 254
    echo "arn:aws:ecs:us-east-1:1:task-definition/${family}:7" ;;
  "ecs describe-task-definition "*)
    td="$(sed -E 's/.*--task-definition ([^ ]+).*/\1/' <<<"$args")"; family="${td##*/}"; svc="${family%%:*}"; svc="${svc%-*}"
    value="$(lookup "$svc")"
    test "$value" = none || printf 'other-value\t%s\n' "$value" ;;
  *) echo "unexpected aws $args" >&2; exit 2 ;;
esac
AWS
# Fake gh api. COMMITS maps release refs to commits ("ref=sha"); a ref not
# listed fails. RELATIONS maps a running commit to the compare status of
# <running>...<this commit> ("sha=status"); "fail" fails the call.
cat >"$work/gh" <<'GH'
#!/usr/bin/env bash
shift # api
path="$1"
find_in() { local key="$1"; shift; for pair in "$@"; do test "${pair%%=*}" = "$key" && { echo "${pair#*=}"; return 0; }; done; return 1; }
case "$path" in
  */commits/*) find_in "${path##*/commits/}" $COMMITS || exit 1 ;;
  */compare/*)
    base="${path##*/compare/}"; base="${base%%...*}"
    status="$(find_in "$base" $RELATIONS)" || exit 1
    test "$status" = fail && exit 1; echo "$status" ;;
  *) echo "unexpected gh api $path" >&2; exit 2 ;;
esac
GH
chmod +x "$work/aws" "$work/gh"

pass=0 fail=0
# name, SERVICES_INPUT, RELEASES, COMMITS, RELATIONS, expected "skip=.." or "error"
run_case() {
  local got out="$work/out" summary="$work/summary"
  : >"$out"; : >"$summary"
  if PATH="$work:$PATH" GITHUB_OUTPUT="$out" GITHUB_STEP_SUMMARY="$summary" GUARD_RETRY_SECONDS=0 \
    GITHUB_REPOSITORY=org/app GITHUB_SHA=aaa APP=web CLUSTER=c DEPLOY_ENV=prod \
    SERVICES_INPUT="$2" RELEASES="$3" COMMITS="$4" RELATIONS="$5" \
    bash -euo pipefail "$work/recheck.sh" >/dev/null 2>&1; then
    got="$(grep '^skip=' "$out" | tail -n 1)"
  else
    got=error
  fi
  if test "$got" = "$6"; then
    pass=$((pass + 1)); echo "ok   $1"
  else
    fail=$((fail + 1)); echo "FAIL $1: got '$got', want '$6'"
  fi
}

two='["api","worker"]'
run_case "prod behind this commit: deploys" "" "web=v2026.11.15.3" "v2026.11.15.3=ppp" "ppp=ahead" "skip=false"
run_case "prod on this commit (retry): deploys" "" "web=v2026.11.15.3" "v2026.11.15.3=aaa" "aaa=identical" "skip=false"
run_case "prod ahead of this commit: skipped" "" "web=v2026.11.15.3" "v2026.11.15.3=ppp" "ppp=behind" "skip=true"
run_case "staging sha release ahead: skipped" "" "web=sha-0123456789ab" "0123456789ab=ppp" "ppp=behind" "skip=true"
run_case "prod off this history: error" "" "web=v2026.11.15.3" "v2026.11.15.3=ppp" "ppp=diverged" "error"
run_case "one of two services ahead: skipped" "$two" "api=v2026.11.15.3 worker=v2026.11.15.5" \
  "v2026.11.15.3=ppp v2026.11.15.5=qqq" "ppp=ahead qqq=behind" "skip=true"
run_case "both services behind: deploys" "$two" "api=v2026.11.15.3 worker=v2026.11.15.3" \
  "v2026.11.15.3=ppp" "ppp=ahead" "skip=false"
run_case "no SENTRY_RELEASE: deploys" "" "web=none" "" "" "skip=false"
run_case "unknown SENTRY_RELEASE: deploys" "" "web=latest" "" "" "skip=false"
run_case "service unreadable: deploys" "" "" "" "" "skip=false"
run_case "release commit unreadable: deploys" "" "web=v2026.11.15.3" "" "" "skip=false"
run_case "compare unreadable: deploys" "" "web=v2026.11.15.3" "v2026.11.15.3=ppp" "ppp=fail" "skip=false"

echo "${pass} passed, ${fail} failed"
test "$fail" -eq 0
