#!/usr/bin/env bash
# Runs the "awsvpc-network" lines exactly as both deliver.yml copies ship them
# (between their BEGIN/END markers) against fixtures, with a stub `aws`:
#
# - a bridge revision runs the migration with no --network-configuration;
# - an awsvpc revision passes the service's own networkConfiguration;
# - an awsvpc revision whose service has none stops the deploy.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

for wf in .depot/workflows/deliver.yml .github/workflows/deliver.yml; do
  awk '/# BEGIN awsvpc-network/{on=1} on{print} /# END awsvpc-network/{on=0}' "$repo_root/$wf" | sed -E 's/^ +//' >"$work/net.sh"
  grep -q 'END awsvpc-network' "$work/net.sh" || { echo "FAIL: awsvpc-network markers not found in $wf"; exit 1; }

  run_case() { # name, networkMode, service networkConfiguration JSON, expect: none|passed|stop
    local dir="$work/$1" rc=0 out
    mkdir -p "$dir/bin"
    jq -n --arg m "$2" '{family: "svc", networkMode: $m, containerDefinitions: [{name: "web"}]}' >"$dir/svc.json"
    printf '#!/bin/sh\necho %s\n' "'$3'" >"$dir/bin/aws"
    chmod +x "$dir/bin/aws"
    out="$(PATH="$dir/bin:$PATH" workdir="$dir" family=svc CLUSTER=c \
      bash -euo pipefail -c '. "$1"; if test ${#network[@]} -eq 0; then echo NETWORK=none; else echo "NETWORK=${network[1]}"; fi' _ "$work/net.sh" 2>&1)" || rc=$?
    case "$4" in
      stop) if test "$rc" != 0; then ok "$wf $1"; else bad "$wf $1 (expected a stop, got: $out)"; fi ;;
      none) if test "$rc" = 0 && grep -qx 'NETWORK=none' <<<"$out"; then ok "$wf $1"; else bad "$wf $1 (rc=$rc out=$out)"; fi ;;
      passed) if test "$rc" = 0 && grep -q 'NETWORK={"awsvpcConfiguration"' <<<"$out"; then ok "$wf $1"; else bad "$wf $1 (rc=$rc out=$out)"; fi ;;
    esac
  }

  run_case bridge-takes-no-network bridge 'null' none
  run_case awsvpc-passes-service-network awsvpc '{"awsvpcConfiguration":{"subnets":["subnet-1"],"securityGroups":["sg-1"],"assignPublicIp":"DISABLED"}}' passed
  run_case awsvpc-without-service-network-stops awsvpc 'null' stop
done

echo "$pass passed, $fail failed"
test "$fail" = 0
