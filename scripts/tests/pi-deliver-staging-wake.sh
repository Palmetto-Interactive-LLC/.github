#!/usr/bin/env bash
# Runs the "staging-wake" lines exactly as pi-deliver.yml ships them (between
# its BEGIN/END markers) against a fake DescribeServices, and checks that a
# staging deploy wakes a service at 0 tasks to 1 and leaves everything else as
# it is (a staging service already up, and prod at any count).
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$repo_root/.github/workflows/pi-deliver.yml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

awk '/# BEGIN staging-wake/{on=1} on{print} /# END staging-wake/{on=0}' "$workflow" \
  | sed -E 's/^ {12}//' >"$work/wake.sh"
grep -q 'END staging-wake' "$work/wake.sh" || { echo "FAIL: markers not found in $workflow"; exit 1; }

pass=0 fail=0
run_case() { # name, DEPLOY_ENV, desired count DescribeServices returns, expected count args
  local got
  got="$(DEPLOY_ENV="$2" DESIRED="$3" CLUSTER="pi-platform-prod" family="site-$2" bash -euo pipefail -c '
    aws() { echo "$DESIRED"; }
    . "$1"
    echo "args=${count[*]+${count[*]}}"' _ "$work/wake.sh" 2>&1 | tail -n 1)"
  if test "$got" = "args=$4"; then
    pass=$((pass + 1)); echo "ok   $1"
  else
    fail=$((fail + 1)); echo "FAIL $1: got '$got', want 'args=$4'"
  fi
}

run_case "staging at 0 wakes to 1" staging 0 "--desired-count 1"
run_case "staging at 1 keeps its count" staging 1 ""
run_case "prod at 0 is never touched" prod 0 ""
run_case "prod at 2 is never touched" prod 2 ""

echo "${pass} passed, ${fail} failed"
test "$fail" -eq 0
