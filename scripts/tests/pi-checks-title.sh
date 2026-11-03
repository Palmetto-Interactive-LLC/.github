#!/usr/bin/env bash
# Runs the "pr-title" lines exactly as .depot/workflows/pi-checks.yml ships them
# (between its BEGIN/END markers) against sample pull request titles and merge
# queue messages, and checks which pass.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$repo_root/.depot/workflows/pi-checks.yml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

awk '/# BEGIN pr-title/{on=1} on{print} /# END pr-title/{on=0}' "$workflow" \
  | sed -E 's/^ {10}//' >"$work/title.sh"
grep -q 'END pr-title' "$work/title.sh" || { echo "FAIL: markers not found in $workflow"; exit 1; }

pass=0 fail=0
run_case() { # name, PR_TITLE, MERGE_MESSAGE, expected exit status
  local status=0
  PR_TITLE="$2" MERGE_MESSAGE="$3" bash -euo pipefail "$work/title.sh" >/dev/null 2>&1 || status=$?
  if test "$status" -eq "$4"; then
    pass=$((pass + 1)); echo "ok   $1"
  else
    fail=$((fail + 1)); echo "FAIL $1: exit $status, want $4"
  fi
}

run_case "feat with scope" "feat(ecs-cluster): host egress from a fixed Elastic IP pool" "" 0
run_case "fix without scope" "fix: stop paging on planned changes" "" 0
run_case "breaking change" "feat(api)!: drop v1" "" 0
run_case "scope with slash and dot" "chore(deps/go.mod): bump" "" 0
run_case "GitHub revert title" 'Revert "feat: x"' "" 0
run_case "merge queue message, first line only" "" $'ci: add merge_group (#12)\n\nbody that is not checked' 0
run_case "no title on a push" "" "" 0
run_case "plain sentence" "Retire idle Marsh orchestrators" "" 1
run_case "unknown type" "cognee: add search" "" 1
run_case "uppercase type" "Feat: x" "" 1
run_case "missing subject" "feat:" "" 1
run_case "no space after colon" "feat:x" "" 1
run_case "merge queue message, bad title" "" $'Retire things (#3)\n\nfeat: in the body' 1
run_case "text and the bad title in the queue only" "" "WIP" 1

echo "${pass} passed, ${fail} failed"
test "$fail" -eq 0
