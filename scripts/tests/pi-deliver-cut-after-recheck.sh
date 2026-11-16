#!/usr/bin/env bash
# Checks that .github/workflows/deliver.yml cuts a release tag only after the
# deploy re-check, inside the locked deploy job, so a skipped deploy leaves no
# tag: the tag is created in exactly one step, that step is in the deploy job
# after "id: recheck", its condition requires the re-check not to have
# skipped, and every step after the re-check that touches AWS or tags carries
# the same condition.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$repo_root/.github/workflows/deliver.yml"
gate="steps.recheck.outputs.skip != 'true'"
pass=0 fail=0
check() { # name, command...
  local name="$1"; shift
  if "$@"; then pass=$((pass + 1)); echo "ok   $name"; else fail=$((fail + 1)); echo "FAIL $name"; fi
}

# Line numbers of the deploy job, the re-check step and every tag-creating line.
deploy_start="$(grep -n '^  deploy:$' "$workflow" | cut -d: -f1)"
deploy_end="$(awk -v s="$deploy_start" 'NR > s && /^  [a-z][a-z0-9_-]*:$/ {print NR; exit}' "$workflow")"
deploy_end="${deploy_end:-$(($(wc -l <"$workflow") + 1))}"
recheck="$(grep -n '^        id: recheck$' "$workflow" | cut -d: -f1)"
creates="$(grep -n 'gh release create' "$workflow" | cut -d: -f1)"

# Prints the "if:" of the step that contains line $1.
step_if() {
  awk -v n="$1" '
    /^      - name:/ { if (NR > n) exit; cond = "" }
    /^        if:/   { cond = $0 }
    END { print cond }' "$workflow"
}

check "the deploy job exists" test -n "$deploy_start"
check "the re-check is in the deploy job" test "$recheck" -gt "$deploy_start" -a "$recheck" -lt "$deploy_end"
check "one step creates the release tag" test "$(wc -w <<<"$creates")" -eq 1
check "the tag is created in the deploy job, after the re-check" test "$creates" -gt "$recheck" -a "$creates" -lt "$deploy_end"
check "a skipped re-check skips the cut" grep -qF "$gate" <<<"$(step_if "$creates")"
check "no other job pushes a tag" test "$(grep -c 'git push.*tag\|git/refs.*tags' "$workflow" || true)" -eq 0

# Every step after the re-check in the deploy job is gated on it.
while read -r line; do
  name="$(sed -n "${line}p" "$workflow" | sed 's/^      - name: //')"
  check "gated on the re-check: ${name}" grep -qF "$gate" <<<"$(step_if "$((line + 1))")"
done < <(awk -v s="$recheck" -v e="$deploy_end" 'NR > s && NR < e && /^      - name:/ {print NR}' "$workflow")

echo "${pass} passed, ${fail} failed"
test "$fail" -eq 0
