#!/usr/bin/env bash
# Runs the "rollback-cause" lines exactly as pi-deliver.yml ships them (between
# its BEGIN/END markers) against DescribeServices output for a deployment ECS
# failed and rolled back, and checks the error names the real cause.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$repo_root/.github/workflows/pi-deliver.yml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

awk '/# BEGIN rollback-cause/{on=1} on{print} /# END rollback-cause/{on=0}' "$workflow" \
  | sed -E 's/^ {16}//' >"$work/cause.sh"
grep -q 'END rollback-cause' "$work/cause.sh" || { echo "FAIL: markers not found in $workflow"; exit 1; }

arn="arn:aws:ecs:us-east-1:1:task-definition/site-prod:9"
svc_with() { # $1 = rolloutStateReason of the failed deployment
  jq -nc --arg arn "$arn" --arg reason "$1" '{
    deploymentConfiguration: {alarms: {alarmNames: ["deploy-gate-site-prod-5xx", "deploy-gate-site-prod-errors"], enable: true, rollback: true}},
    deployments: [
      {status: "PRIMARY", taskDefinition: "arn:aws:ecs:us-east-1:1:task-definition/site-prod:8", rolloutState: "IN_PROGRESS"},
      {status: "ACTIVE", taskDefinition: $arn, rolloutState: "FAILED", rolloutStateReason: $reason}
    ]}'
}

pass=0 fail=0
run_case() { # name, reason, expected text
  local out
  out="$(svc="$(svc_with "$2")" arn="$arn" family="site-prod" bash -euo pipefail "$work/cause.sh" 2>&1)"
  if grep -qF -- "$3" <<<"$out"; then
    pass=$((pass + 1)); echo "ok    $1"
  else
    fail=$((fail + 1)); echo "FAIL  $1: $out"
  fi
}

run_case alarm "ECS deployment failed: alarm(s) detected." \
  "::error::site-prod deployment of site-prod:9 failed and ECS rolled it back: a deployment alarm went to ALARM, so the new tasks served 5xx or logged errors (gates: deploy-gate-site-prod-5xx, deploy-gate-site-prod-errors). ECS: ECS deployment failed: alarm(s) detected."
run_case circuit-breaker "ECS deployment circuit breaker: tasks failed to start." \
  "failed and ECS rolled it back: the circuit breaker stopped it: the new tasks failed to start or failed their health checks. ECS: ECS deployment circuit breaker: tasks failed to start."
run_case unknown "" "failed and ECS rolled it back: ECS failed the deployment. ECS: no reason given"

# The alarm case must not blame the circuit breaker.
out="$(svc="$(svc_with "ECS deployment failed: alarm(s) detected.")" arn="$arn" family="site-prod" bash -euo pipefail "$work/cause.sh" 2>&1)"
if grep -q "circuit breaker" <<<"$out"; then fail=$((fail + 1)); echo "FAIL  alarm-not-breaker: $out"; else pass=$((pass + 1)); echo "ok    alarm-not-breaker"; fi

echo
echo "$pass passed, $fail failed"
test "$fail" -eq 0
