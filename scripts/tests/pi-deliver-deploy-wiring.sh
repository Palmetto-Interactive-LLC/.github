#!/usr/bin/env bash
# A release on main must fail, by name, when the deploy switch or wiring is missing, not skip
# Build and Deploy and end green (membl.io went five days unshipped that way, 2026-11-14 to 11-19).
#
# Runs the "deploy-wiring" lines exactly as .github/workflows/deliver.yml ships them (between
# their BEGIN/END markers) and checks that:
#
# - ECS_DEPLOY_ENABLED other than exactly "true" (empty, "false", "True") fails and the ::error::
#   names ECS_DEPLOY_ENABLED;
# - an empty push-role-arn fails and the ::error:: names PI_PLATFORM_IMAGE_PUSH_ROLE_ARN;
# - both missing name both; a switch that is "true" with a push role passes quietly;
# - an odd switch value cannot inject a workflow command.
#
# It also pins the wiring around the block, which no run of the block can show: the step sits in
# the Guard job (which runs only on refs/heads/main), runs only for mode=release (a staging-mode run
# keeps its quiet skip, see pi-deliver-head-guard.sh), comes after the mode check and before the head
# guard, is not continue-on-error, reads the two inputs, and Build and Deploy still depend on the
# Guard, so a failed Guard ships nothing.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$repo_root/.github/workflows/deliver.yml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

awk '/# BEGIN deploy-wiring/{on=1} on{print} /# END deploy-wiring/{on=0}' "$workflow" \
  | sed -E 's/^ {10}//' >"$work/wiring.sh"
grep -q 'END deploy-wiring' "$work/wiring.sh" || { echo "FAIL: markers not found in $workflow"; exit 1; }

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# --- the block -----------------------------------------------------------------------------
# name, want (pass|fail), DEPLOY_ENABLED, PUSH_ROLE_ARN, then patterns the output must (or, with
# a leading "!", must not) match.
run_case() {
  local name="$1" want="$2" enabled="$3" push="$4" rc=0 pattern
  shift 4
  : >"$work/summary"
  DEPLOY_ENABLED="$enabled" PUSH_ROLE_ARN="$push" GITHUB_STEP_SUMMARY="$work/summary" \
    bash -euo pipefail "$work/wiring.sh" >"$work/out" 2>&1 || rc=$?
  if test "$want" = pass && test "$rc" != 0; then bad "$name: exited $rc, wanted 0"; return; fi
  if test "$want" = fail && test "$rc" != 1; then bad "$name: exited $rc, wanted 1"; return; fi
  for pattern in "$@"; do
    if [[ "$pattern" == '!'* ]]; then
      if grep -Eq -- "${pattern#!}" "$work/out" "$work/summary"; then bad "$name: output matches ${pattern#!}"; return; fi
    elif ! grep -Eq -- "$pattern" "$work/out"; then
      bad "$name: output lacks $pattern"; return
    fi
  done
  ok "$name"
}

arn="arn:aws:iam::111111111111:role/fixture-push"
run_case "switch on, push role set: passes quietly" pass true "$arn" '!::error::' '!ECS_DEPLOY_ENABLED'
run_case "switch empty: fails naming ECS_DEPLOY_ENABLED" fail "" "$arn" '^::error::Release on main cannot ship: ECS_DEPLOY_ENABLED' '!PI_PLATFORM_IMAGE_PUSH_ROLE_ARN'
run_case "switch false: fails naming ECS_DEPLOY_ENABLED" fail false "$arn" '^::error::Release on main cannot ship: ECS_DEPLOY_ENABLED .*is .false' '!PI_PLATFORM_IMAGE_PUSH_ROLE_ARN'
run_case "switch True (not exactly true): fails" fail True "$arn" '^::error::Release on main cannot ship: ECS_DEPLOY_ENABLED'
run_case "push role empty: fails naming PI_PLATFORM_IMAGE_PUSH_ROLE_ARN" fail true "" '^::error::Release on main cannot ship: PI_PLATFORM_IMAGE_PUSH_ROLE_ARN' '!ECS_DEPLOY_ENABLED'
run_case "both missing: names both" fail "" "" 'ECS_DEPLOY_ENABLED' 'PI_PLATFORM_IMAGE_PUSH_ROLE_ARN'
run_case "failure says nothing would ship and is in the job summary" fail "" "$arn" 'nothing shipped'
if grep -q 'Release failed' "$work/summary" && grep -q 'ECS_DEPLOY_ENABLED' "$work/summary"; then ok "failure is written to the job summary"; else bad "failure is not in the job summary"; fi
run_case "odd switch value cannot inject a workflow command" fail $'x\n::error::injected' "$arn" '!^::error::injected' '!^::set-output'

# --- the wiring around the block -------------------------------------------------------------
step_name='Require the deploy switch and wiring (release)'
step="$(awk -v want="      - name: $step_name" '/^      - name: /{on = ($0 == want)} on{print}' "$workflow")"
guard="$(awk '/^  guard:$/{on=1; next} on && /^  [a-z][a-z-]*:$/{on=0} on{print}' "$workflow")"

test -n "$step" && ok "the step exists" || bad "no step named '$step_name'"
grep -qx "        if: inputs.mode == 'release'" <<<"$step" && ok "the step runs for mode=release only" || bad "the step is not limited to mode=release"
grep -q 'continue-on-error' <<<"$step" && bad "the step has continue-on-error" || ok "the step cannot be made to pass"
grep -qx '          DEPLOY_ENABLED: ${{ inputs.deploy-enabled }}' <<<"$step" && ok "the step reads deploy-enabled" || bad "the step does not read deploy-enabled"
grep -qx '          PUSH_ROLE_ARN: ${{ inputs.push-role-arn }}' <<<"$step" && ok "the step reads push-role-arn" || bad "the step does not read push-role-arn"
grep -qx "    if: github.ref == 'refs/heads/main'" <<<"$guard" && ok "the Guard job runs on refs/heads/main" || bad "the Guard job is not limited to refs/heads/main"

line() { grep -n -F -- "$1" <<<"$guard" | head -n 1 | cut -d: -f1; }
mode_at="$(line '- name: Check the delivery mode')" wiring_at="$(line "- name: $step_name")" head_at="$(line '- name: Skip a commit that would roll a service back')"
if test -n "$mode_at" && test -n "$wiring_at" && test -n "$head_at" && test "$mode_at" -lt "$wiring_at" && test "$wiring_at" -lt "$head_at"; then
  ok "the step runs after the mode check and before the head guard"
else
  bad "the step is not between the mode check and the head guard (${mode_at:-?} ${wiring_at:-?} ${head_at:-?})"
fi

# A failed Guard has no outputs, so Build and Deploy must not run on that: Build needs
# build == 'true', Deploy needs stale == 'false'.
awk '/^  build:$/{on=1; next} on && /^  [a-z][a-z-]*:$/{on=0} on{print}' "$workflow" >"$work/build-job"
awk '/^  deploy:$/{on=1; next} on && /^  [a-z][a-z-]*:$/{on=0} on{print}' "$workflow" >"$work/deploy-job"
grep -qx '    needs: guard' "$work/build-job" && grep -qx "    if: needs.guard.outputs.build == 'true'" "$work/build-job" \
  && ok "Build needs the Guard and runs only when it says build" || bad "Build does not depend on the Guard's output"
grep -qx '    needs: \[guard, build\]' "$work/deploy-job" && grep -q "needs.guard.outputs.stale == 'false'" "$work/deploy-job" \
  && ok "Deploy needs the Guard and runs only when it says not stale" || bad "Deploy does not depend on the Guard's output"

echo "${pass} passed, ${fail} failed"
test "$fail" -eq 0
