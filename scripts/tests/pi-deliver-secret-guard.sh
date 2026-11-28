#!/usr/bin/env bash
# Runs the "live-revision", "secret-guard", and "migrate-cleanup" blocks
# exactly as .github/workflows/deliver.yml ships them (between their
# BEGIN/END markers) against generic fixtures, and checks:
#
# - the base revision is the service's live one, read from DescribeServices,
#   and anything that is not a pinned task-definition ARN (with numeric
#   revision) of the same family stops the deploy;
# - a serving revision with a migrator secret in EITHER .name OR .valueFrom
#   (case-insensitive token boundary, across any container), malformed secrets,
#   or an undeclared secret (ECS_SERVING_SECRETS) stops the deploy without
#   echoing raw secret ARNs, and a clean revision passes;
# - the migration step deregisters its migration-only revision on exit AND is
#   backed by an always() cleanup step before service rollout.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# The live reusable workflow is the GitHub Actions one (callers use it). The
# .depot copy is frozen by pi-deliver-staging-seed.sh, so it is not tested here.
workflow="$repo_root/.github/workflows/deliver.yml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

extract() { # marker, indent
  awk "/# BEGIN $1/{on=1} on{print} /# END $1/{on=0}" "$workflow" | sed -E "s/^ {$2}//" >"$work/$1.sh"
  grep -q "END $1" "$work/$1.sh" || { echo "FAIL: $1 markers not found in $workflow"; exit 1; }
}
extract live-revision 12
extract secret-guard 12
extract migrate-cleanup 10

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

# --- live-revision -----------------------------------------------------------
base_case() { # name, what DescribeServices returns, expect: ok|stop, expected base
  local out rc=0
  out="$(LIVE="$2" CLUSTER=example-cluster family=example-app-staging bash -euo pipefail -c '
    aws() { echo "$LIVE"; }
    . "$1"
    echo "base=$base"' _ "$work/live-revision.sh" 2>&1)" || rc=$?
  if test "$3" = "ok" && test "$rc" = 0 && grep -qx "base=$4" <<<"$out"; then ok "$1"
  elif test "$3" = "stop" && test "$rc" != 0 && grep -q '::error::' <<<"$out"; then ok "$1"
  else bad "$1 (rc=$rc): $out"; fi
}
live="arn:aws:ecs:us-east-1:111111111111:task-definition/example-app-staging:60"
base_case "uses the service's live revision" "$live" ok "$live"
base_case "no service: stops" "None" stop
base_case "empty output: stops" "" stop
base_case "another family's revision: stops" "arn:aws:ecs:us-east-1:111111111111:task-definition/example-app-prod:6" stop
base_case "unpinned family without revision: stops" "arn:aws:ecs:us-east-1:111111111111:task-definition/example-app-staging" stop
base_case "non-numeric revision: stops" "arn:aws:ecs:us-east-1:111111111111:task-definition/example-app-staging:latest" stop
base_case "extra colon suffix: stops" "arn:aws:ecs:us-east-1:111111111111:task-definition/example-app-staging:60:61" stop
grep -q 'describe-task-definition --task-definition "\$base"' "$workflow" && ok "the copy reads \$base" || bad "the copy does not read \$base"
grep -q 'describe-task-definition --task-definition "\$family" --query taskDefinition' "$workflow" \
  && bad "a family-latest copy is still in the workflow" || ok "no family-latest copy left"

# --- secret-guard ------------------------------------------------------------
taskdef() { # secret names...
  jq -nc --args '{containerDefinitions: [{name: "web", secrets: [$ARGS.positional[] | {name: ., valueFrom: ("arn:aws:ssm:us-east-1:111111111111:parameter/staging/app/" + .)}]}]}' "$@"
}
declared='{"example-app-staging": ["AUTH_SECRET", "DATABASE_URL", "DATABASE_READER_URL", "LLM_API_KEY"], "example-app-prod": ["AUTH_SECRET", "DATABASE_URL"]}'

guard_json_case() { # name, expect: pass|stop, SERVING_SECRETS, family, taskdef JSON, optional must-match regex, optional must-not-match regex
  local name="$1" want="$2" serving="$3" fam="$4" json="$5" must="${6:-}" forbid="${7:-}" out rc=0
  mkdir -p "$work/td"
  printf '%s\n' "$json" >"$work/td/${fam}.json"
  out="$(SERVING_SECRETS="$serving" workdir="$work/td" family="$fam" bash -euo pipefail "$work/secret-guard.sh" 2>&1)" || rc=$?
  if test "$want" = "pass" && test "$rc" = 0; then
    ok "$name"
  elif test "$want" = "stop" && test "$rc" != 0 && grep -q '::error::' <<<"$out"; then
    if test -n "$must" && ! grep -Eq -- "$must" <<<"$out"; then
      bad "$name (missing expected pattern $must): $out"
    elif test -n "$forbid" && grep -Eq -- "$forbid" <<<"$out"; then
      bad "$name (matched forbidden pattern $forbid): $out"
    else
      ok "$name"
    fi
  else
    bad "$name (rc=$rc): $out"
  fi
}

guard_case() { # name, expect: pass|stop, SERVING_SECRETS, family, secret names...
  local name="$1" want="$2" serving="$3" fam="$4"
  shift 4
  guard_json_case "$name" "$want" "$serving" "$fam" "$(taskdef "$@")"
}

guard_case "declared secrets pass" pass "$declared" example-app-staging AUTH_SECRET DATABASE_URL LLM_API_KEY
guard_case "DATABASE_MIGRATOR_URL secret name stops" stop "$declared" example-app-staging AUTH_SECRET DATABASE_URL DATABASE_MIGRATOR_URL
guard_case "lowercase migrator secret name stops" stop "$declared" example-app-staging AUTH_SECRET db_migrator_url
guard_case "migrator secret name stops even without a declared list" stop "" example-app-staging DATABASE_URL DATABASE_MIGRATOR_URL
guard_case "MIGRATOR_PASSWORD stops" stop "$declared" example-app-staging MIGRATOR_PASSWORD
guard_case "undeclared secret stops" stop "$declared" example-app-prod AUTH_SECRET ONE_OFF_TOKEN
guard_case "service missing from declared list stops" stop "$declared" example-unknown-staging AUTH_SECRET
guard_case "no secrets at all passes" pass '{"example-static-staging": []}' example-static-staging
guard_case "no declared list: only the migrator check, clean passes" pass "" example-static-staging SESSION_SECRET

guard_json_case "DATABASE_URL with Secrets Manager migrator valueFrom stops without leaking ARN" stop "$declared" example-app-prod \
  '{"containerDefinitions":[{"name":"web","secrets":[{"name":"DATABASE_URL","valueFrom":"arn:aws:secretsmanager:us-east-1:111111111111:secret:env/app/db/migrator:url::"}]}]}' \
  'DATABASE_URL \(valueFrom\)' '111111111111|secretsmanager'

guard_json_case "DATABASE_URL with suffixed Secrets Manager migrator valueFrom stops" stop "$declared" example-app-prod \
  '{"containerDefinitions":[{"name":"web","secrets":[{"name":"DATABASE_URL","valueFrom":"arn:aws:secretsmanager:us-east-1:111111111111:secret:env/app/db/migrator-AbCdEf:url::"}]}]}' \
  'DATABASE_URL \(valueFrom\)' '111111111111'

guard_json_case "DATABASE_URL with SSM migrator path valueFrom stops" stop "$declared" example-app-prod \
  '{"containerDefinitions":[{"name":"web","secrets":[{"name":"DATABASE_URL","valueFrom":"arn:aws:ssm:us-east-1:111111111111:parameter/prod/app/db/migrator/url"}]}]}' \
  'DATABASE_URL \(valueFrom\)' '111111111111'

guard_json_case "DATABASE_URL with uppercase SSM MIGRATOR valueFrom stops" stop "$declared" example-app-prod \
  '{"containerDefinitions":[{"name":"web","secrets":[{"name":"DATABASE_URL","valueFrom":"arn:aws:ssm:us-east-1:111111111111:parameter/prod/app/DB_MIGRATOR"}]}]}' \
  'DATABASE_URL \(valueFrom\)' '111111111111'

guard_json_case "DATABASE_URL with dot-delimited migrator valueFrom stops" stop "$declared" example-app-prod \
  '{"containerDefinitions":[{"name":"web","secrets":[{"name":"DATABASE_URL","valueFrom":"arn:aws:ssm:us-east-1:111111111111:parameter/prod/app/db.migrator.url"}]}]}' \
  'DATABASE_URL \(valueFrom\)' '111111111111'

guard_json_case "migrator valueFrom stops even without SERVING_SECRETS" stop "" example-app-prod \
  '{"containerDefinitions":[{"name":"web","secrets":[{"name":"DATABASE_URL","valueFrom":"arn:aws:ssm:us-east-1:111111111111:parameter/prod/app/db/migrator/url"}]}]}' \
  'DATABASE_URL \(valueFrom\)' '111111111111'

guard_json_case "sidecar container carrying migrator valueFrom stops" stop "$declared" example-app-prod \
  '{"containerDefinitions":[{"name":"web","secrets":[{"name":"AUTH_SECRET","valueFrom":"arn:aws:ssm:us-east-1:111111111111:parameter/prod/app/auth"}]},{"name":"sidecar","secrets":[{"name":"DATABASE_URL","valueFrom":"arn:aws:ssm:us-east-1:111111111111:parameter/prod/app/db/migrator/url"}]}]}' \
  'DATABASE_URL \(valueFrom\)' '111111111111'

guard_json_case "duplicate secret name where second entry carries migrator valueFrom stops" stop "$declared" example-app-prod \
  '{"containerDefinitions":[{"name":"web","secrets":[{"name":"DATABASE_URL","valueFrom":"arn:aws:ssm:us-east-1:111111111111:parameter/prod/app/db/core/url"},{"name":"DATABASE_URL","valueFrom":"arn:aws:secretsmanager:us-east-1:111111111111:secret:env/app/db/migrator:url::"}]}]}' \
  'DATABASE_URL \(valueFrom\)' '111111111111'

guard_json_case "non-migrator lookalike paths pass" pass "$declared" example-app-prod \
  '{"containerDefinitions":[{"name":"web","secrets":[{"name":"AUTH_SECRET","valueFrom":"arn:aws:ssm:us-east-1:111111111111:parameter/prod/app/migration_status"},{"name":"DATABASE_URL","valueFrom":"arn:aws:ssm:us-east-1:111111111111:parameter/prod/app/nonmigrator/core/url"}]}]}'

guard_json_case "malformed secret missing valueFrom fails closed" stop "$declared" example-app-prod \
  '{"containerDefinitions":[{"name":"web","secrets":[{"name":"DATABASE_URL"}]}]}'

# --- migration cleanup -------------------------------------------------------
grep -q 'trap cleanup EXIT' "$workflow" \
  && grep -q 'aws ecs deregister-task-definition --task-definition "\$migrate_rev"' "$workflow" \
  && grep -q 'migrate_rev="\$arn"' "$workflow" \
  && grep -q 'printf '\''%s\\n'\'' "\$migrate_rev" > "\$migrate_rev_file"' "$workflow" \
  && ok "migration-only revision is recorded and deregistered on exit" \
  || bad "migration step does not record and deregister its revision"

cleanup_step="$(awk -v want="      - name: Deregister migration-only task definition" '/^      - name: /{on = ($0 == want)} on{print}' "$workflow")"
if test -n "$cleanup_step" \
  && grep -qx "        if: always() && inputs.migrate-command != '' && steps.recheck.outputs.skip != 'true'" <<<"$cleanup_step"; then
  ok "always() migration cleanup step is wired"
else
  bad "always() migration cleanup step missing or misconfigured"
fi

mig_line="$(grep -n -F -- '- name: Run pre-deploy migration' "$workflow" | head -n 1 | cut -d: -f1)"
clean_line="$(grep -n -F -- '- name: Deregister migration-only task definition' "$workflow" | head -n 1 | cut -d: -f1)"
roll_line="$(grep -n -F -- '- name: Roll services and wait for a stable deployment' "$workflow" | head -n 1 | cut -d: -f1)"
if test -n "$mig_line" && test -n "$clean_line" && test -n "$roll_line" \
  && test "$mig_line" -lt "$clean_line" && test "$clean_line" -lt "$roll_line"; then
  ok "always() cleanup step runs after migration and before service roll"
else
  bad "always() cleanup step ordering wrong (${mig_line:-?} ${clean_line:-?} ${roll_line:-?})"
fi

cleanup_case() { # name, rev_content, describe_status, deregister_rc, expect: pass|stop, expect_calls
  local name="$1" rev="$2" desc_status="$3" dereg_rc="$4" want="$5" want_calls="$6"
  local rt="$work/cleanup-$pass-$fail" out rc=0 calls=""
  mkdir -p "$rt/taskdefs"
  if test -n "$rev"; then
    printf '%s\n' "$rev" >"$rt/taskdefs/migrate-rev"
    printf '{}\n' >"$rt/taskdefs/example-app-prod-migrate.json"
  fi
  : >"$rt/calls"
  out="$(RUNNER_TEMP="$rt" DESC_STATUS="$desc_status" DEREG_RC="$dereg_rc" CALLS="$rt/calls" bash -euo pipefail -c '
    aws() {
      printf "%s\n" "$*" >>"$CALLS"
      case "$2" in
        describe-task-definition) echo "$DESC_STATUS"; return 0 ;;
        deregister-task-definition) return "$DEREG_RC" ;;
        *) return 1 ;;
      esac
    }
    . "$1"' _ "$work/migrate-cleanup.sh" 2>&1)" || rc=$?
  calls="$(cat "$rt/calls")"
  if test "$want" = "pass" && test "$rc" = 0 && test ! -e "$rt/taskdefs/migrate-rev"; then
    if test "$want_calls" = "none" && test -z "$calls"; then ok "$name"
    elif test "$want_calls" = "deregister" && grep -q "deregister-task-definition --task-definition $rev" <<<"$calls"; then ok "$name"
    elif test "$want_calls" = "describe-only" && grep -q "describe-task-definition" <<<"$calls" && ! grep -q "deregister-task-definition" <<<"$calls"; then ok "$name"
    else bad "$name (unexpected aws calls: $calls)"; fi
  elif test "$want" = "stop" && test "$rc" != 0 && grep -q '::error::' <<<"$out" && test -s "$rt/taskdefs/migrate-rev"; then
    ok "$name"
  else
    bad "$name (rc=$rc calls=$calls): $out"
  fi
}

mig_arn="arn:aws:ecs:us-east-1:111111111111:task-definition/example-app-prod:99"
cleanup_case "always() cleanup is a no-op when no migrate-rev file exists" "" "" 0 pass none
cleanup_case "always() cleanup deregisters leftover ACTIVE migration revision" "$mig_arn" "ACTIVE" 0 pass deregister
cleanup_case "always() cleanup treats already-INACTIVE revision as clean" "$mig_arn" "INACTIVE" 0 pass describe-only
cleanup_case "always() cleanup fails closed if deregister fails" "$mig_arn" "ACTIVE" 1 stop deregister

echo "${pass} passed, ${fail} failed"
test "$fail" -eq 0
