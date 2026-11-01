#!/usr/bin/env bash
# Runs the "runtime-platform" lines exactly as pi-deliver.yml ships them
# (between their BEGIN/END markers) against fixtures, and checks that the
# registered revision's runtimePlatform.cpuArchitecture follows the image:
#
# - an amd64 image on a live ARM64 revision registers X86_64 (the 2026-11 move);
# - an arm64 image (a release or rollback of a pre-move commit) registers ARM64;
# - an image with no known architecture stops the deploy.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$repo_root/.github/workflows/pi-deliver.yml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

awk '/# BEGIN runtime-platform/{on=1} on{print} /# END runtime-platform/{on=0}' "$workflow" | sed -E 's/^ {12}//' >"$work/rp.sh"
grep -q 'END runtime-platform' "$work/rp.sh" || { echo "FAIL: runtime-platform markers not found in $workflow"; exit 1; }

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

run_case() { # name, image arch, live cpuArchitecture, expect: X86_64|ARM64|stop
  local dir="$work/$1" rc=0 out
  mkdir -p "$dir"
  jq -n --arg a "$3" '{family: "pi-odonofrio-staging", runtimePlatform: {cpuArchitecture: $a, operatingSystemFamily: "LINUX"},
    containerDefinitions: [{name: "web", image: "x"}]}' >"$dir/pi-odonofrio-staging.json"
  out="$(IMAGES="$(jq -nc --arg a "$2" '[{repo: "pi-odonofrio/web", arch: $a}]')" workdir="$dir" family=pi-odonofrio-staging \
    bash -euo pipefail -c '. "$1"' _ "$work/rp.sh" 2>&1)" || rc=$?
  if test "$4" = "stop"; then
    if test "$rc" != 0; then ok "$1"; else bad "$1 (expected a stop, got: $out)"; fi
    return
  fi
  local got
  got="$(jq -r '.runtimePlatform.cpuArchitecture + "/" + .runtimePlatform.operatingSystemFamily' "$dir/pi-odonofrio-staging.json")"
  if test "$rc" = 0 && test "$got" = "$4/LINUX"; then ok "$1"; else bad "$1 (rc=$rc got=$got out=$out)"; fi
}

run_case amd64-image-on-arm64-revision amd64 ARM64 X86_64
run_case amd64-image-on-x86-revision amd64 X86_64 X86_64
run_case arm64-rollback-on-x86-revision arm64 X86_64 ARM64
run_case unknown-arch-stops "" ARM64 stop

echo "$pass passed, $fail failed"
test "$fail" = 0
