#!/usr/bin/env bash
# Runs the "runtime-platform" lines exactly as .depot/workflows/deliver.yml ships them
# (between their BEGIN/END markers) against fixtures, and checks that the
# registered revision's runtimePlatform.cpuArchitecture follows the image:
#
# - an amd64 image on a live ARM64 revision registers X86_64 (the 2026-11 move);
# - an arm64 image (a release or rollback of a pre-move commit) registers ARM64;
# - a multi-arch image (amd64,arm64) registers no runtimePlatform, so the task
#   places on x86_64 and arm64 hosts alike;
# - an image with no known architecture stops the deploy.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$repo_root/.depot/workflows/deliver.yml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

awk '/# BEGIN runtime-platform/{on=1} on{print} /# END runtime-platform/{on=0}' "$workflow" | sed -E 's/^ {12}//' >"$work/rp.sh"
grep -q 'END runtime-platform' "$work/rp.sh" || { echo "FAIL: runtime-platform markers not found in $workflow"; exit 1; }

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

run_case() { # name, image arch, live cpuArchitecture, expect: X86_64|ARM64|none|stop
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
  got="$(jq -r 'if .runtimePlatform == null then "none" else .runtimePlatform.cpuArchitecture + "/" + .runtimePlatform.operatingSystemFamily end' "$dir/pi-odonofrio-staging.json")"
  want="$4/LINUX"; test "$4" = none && want=none
  if test "$rc" = 0 && test "$got" = "$want"; then ok "$1"; else bad "$1 (rc=$rc got=$got out=$out)"; fi
}

run_case amd64-image-on-arm64-revision amd64 ARM64 X86_64
run_case amd64-image-on-x86-revision amd64 X86_64 X86_64
run_case arm64-rollback-on-x86-revision arm64 X86_64 ARM64
run_case multi-arch-on-x86-revision amd64,arm64 X86_64 none
run_case multi-arch-on-arm64-revision amd64,arm64 ARM64 none
run_case unknown-arch-stops "" ARM64 stop
run_case unsupported-arch-set-stops arm64,ppc64le X86_64 stop

echo "$pass passed, $fail failed"
test "$fail" = 0
