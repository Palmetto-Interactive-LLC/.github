#!/usr/bin/env bash
# Runs the "live-revision" and "secret-guard" lines exactly as pi-deliver.yml
# ships them (between their BEGIN/END markers) against fixtures, and checks:
#
# - the base revision is the service's live one, read from DescribeServices,
#   and anything that is not a task-definition ARN of the same family stops the
#   deploy;
# - a serving revision with a *_MIGRATOR_* secret, or a secret pi-platform does
#   not declare for the service (ECS_SERVING_SECRETS), stops the deploy, and a
#   clean one passes;
# - the migration step deregisters its migration-only revision on exit.
#
# The fixture is the 2026-10-30 leak: oswaldcooke-staging:61 served with
# DATABASE_MIGRATOR_URL because the deploy copied the family's newest revision.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$repo_root/.github/workflows/pi-deliver.yml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

extract() { # marker, indent
  awk "/# BEGIN $1/{on=1} on{print} /# END $1/{on=0}" "$workflow" | sed -E "s/^ {$2}//" >"$work/$1.sh"
  grep -q "END $1" "$work/$1.sh" || { echo "FAIL: $1 markers not found in $workflow"; exit 1; }
}
extract live-revision 12
extract secret-guard 12

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# --- live-revision -----------------------------------------------------------
base_case() { # name, what DescribeServices returns, expect: ok|stop, expected base
  local out rc=0
  out="$(LIVE="$2" CLUSTER=pi-platform-prod family=oswaldcooke-staging bash -euo pipefail -c '
    aws() { echo "$LIVE"; }
    . "$1"
    echo "base=$base"' _ "$work/live-revision.sh" 2>&1)" || rc=$?
  if test "$3" = "ok" && test "$rc" = 0 && grep -qx "base=$4" <<<"$out"; then ok "$1"
  elif test "$3" = "stop" && test "$rc" != 0 && grep -q '::error::' <<<"$out"; then ok "$1"
  else bad "$1 (rc=$rc): $out"; fi
}
live="arn:aws:ecs:us-east-1:490600801675:task-definition/oswaldcooke-staging:60"
base_case "uses the service's live revision" "$live" ok "$live"
base_case "no service: stops" "None" stop
base_case "another family's revision: stops" "arn:aws:ecs:us-east-1:490600801675:task-definition/oswaldcooke-prod:6" stop
grep -q 'describe-task-definition --task-definition "\$base"' "$workflow" && ok "the copy reads \$base" || bad "the copy does not read \$base"
grep -q 'describe-task-definition --task-definition "\$family" --query taskDefinition' "$workflow" \
  && bad "a family-latest copy is still in the workflow" || ok "no family-latest copy left"

# --- secret-guard ------------------------------------------------------------
taskdef() { # secret names...
  jq -nc --args '{containerDefinitions: [{name: "web", secrets: [$ARGS.positional[] | {name: ., valueFrom: ("arn:x:" + .)}]}]}' "$@"
}
declared='{"oswaldcooke-staging": ["AUTH_SECRET", "DATABASE_URL", "DATABASE_READER_URL", "LLM_API_KEY"], "oswaldcooke-prod": ["AUTH_SECRET"]}'

guard_case() { # name, expect: pass|stop, SERVING_SECRETS, family, secret names...
  local name="$1" want="$2" serving="$3" fam="$4" out rc=0
  shift 4
  mkdir -p "$work/td"
  taskdef "$@" >"$work/td/${fam}.json"
  out="$(SERVING_SECRETS="$serving" workdir="$work/td" family="$fam" bash -euo pipefail "$work/secret-guard.sh" 2>&1)" || rc=$?
  if test "$want" = "pass" && test "$rc" = 0; then ok "$name"
  elif test "$want" = "stop" && test "$rc" != 0 && grep -q '::error::' <<<"$out"; then ok "$name"
  else bad "$name (rc=$rc): $out"; fi
}
guard_case "declared secrets pass" pass "$declared" oswaldcooke-staging AUTH_SECRET DATABASE_URL LLM_API_KEY
guard_case "the 2026-10-30 leak (DATABASE_MIGRATOR_URL) stops" stop "$declared" oswaldcooke-staging AUTH_SECRET DATABASE_URL DATABASE_MIGRATOR_URL
guard_case "a migrator secret stops even without a declared list" stop "" oswaldcooke-staging DATABASE_URL DATABASE_MIGRATOR_URL
guard_case "a one-off secret (WEBFLOW_TOKEN) stops" stop "$declared" oswaldcooke-prod AUTH_SECRET WEBFLOW_TOKEN
guard_case "a service missing from the declared list stops" stop "$declared" pi-unknown-staging AUTH_SECRET
guard_case "no secrets at all passes" pass '{"pi-odonofrio-staging": []}' pi-odonofrio-staging
guard_case "no declared list: only the migrator check, clean passes" pass "" pi-odonofrio-staging SESSION_SECRET
guard_case "MIGRATOR_PASSWORD stops" stop "$declared" oswaldcooke-staging MIGRATOR_PASSWORD

# --- migration cleanup -------------------------------------------------------
grep -q 'trap cleanup EXIT' "$workflow" && grep -q 'aws ecs deregister-task-definition --task-definition "\$migrate_rev"' "$workflow" \
  && grep -q 'migrate_rev="\$arn"' "$workflow" && ok "migration-only revision is deregistered on exit" \
  || bad "migration step does not deregister its revision"

echo "${pass} passed, ${fail} failed"
test "$fail" -eq 0
