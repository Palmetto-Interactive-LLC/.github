#!/usr/bin/env bash
# Runs the "workflows-match-main" check exactly as pi-release.yml ships it
# (the lines between its BEGIN/END markers) against a fake GitHub contents API.
#
# The rule it guards (verified 2026-10-29 in .github#42): GITHUB_TOKEN gets
# 403 "Resource not accessible by integration" when it tags a commit, or makes
# a release that would create the tag, if that commit's .github/workflows
# differs from main's. pi-release must refuse such a sha before the gates.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$repo_root/.github/workflows/pi-release.yml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

awk '/# BEGIN workflows-match-main/{on=1} on{print} /# END workflows-match-main/{on=0}' "$workflow" \
  | sed -E 's/^ {10}//' >"$work/check.sh"
grep -q 'END workflows-match-main' "$work/check.sh" || { echo "FAIL: markers not found in $workflow"; exit 1; }

# Fake curl: answers GET .../contents/.github?ref=<ref> from $FIXTURES/<ref>.json
# with the status in $FIXTURES/<ref>.code (default 200).
mkdir -p "$work/bin"
cat >"$work/bin/curl" <<'FAKE'
#!/usr/bin/env bash
out="" url=""
while test $# -gt 0; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -w|-H|-X|-d) shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
ref="${url##*ref=}"
code="$(cat "$FIXTURES/$ref.code" 2>/dev/null || echo 200)"
cp "$FIXTURES/$ref.json" "$out" 2>/dev/null || echo '{}' >"$out"
printf '%s' "$code"
FAKE
chmod +x "$work/bin/curl"

dir_listing() { # $1 = workflows tree sha, or "absent"
  if test "$1" = absent; then echo '[{"name":"CODEOWNERS","type":"file","sha":"c0"}]'
  else printf '[{"name":"CODEOWNERS","type":"file","sha":"c0"},{"name":"workflows","type":"dir","sha":"%s"}]' "$1"; fi
}

pass=0 fail=0
# case <name> <release workflows tree> <main workflows tree> <dry_run> <want exit> <want text> [release http code]
run_case() {
  local name="$1" rel="$2" main="$3" dry="$4" want_rc="$5" want_text="$6" rel_code="${7:-200}"
  local sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  export FIXTURES="$work/fx-$name"
  mkdir -p "$FIXTURES"
  dir_listing "$rel" >"$FIXTURES/$sha.json"; echo "$rel_code" >"$FIXTURES/$sha.code"
  dir_listing "$main" >"$FIXTURES/main.json"
  set +e
  out="$(PATH="$work/bin:$PATH" RELEASE_SHA="$sha" DRY_RUN="$dry" GH_TOKEN=t GITHUB_REPOSITORY=o/r RUNNER_TEMP="$work" \
    bash -euo pipefail "$work/check.sh" 2>&1)"
  rc=$?
  set -e
  if test "$rc" = "$want_rc" && grep -qF -- "$want_text" <<<"$out"; then
    pass=$((pass + 1)); echo "ok    $name"
  else
    fail=$((fail + 1)); echo "FAIL  $name: exit $rc (want $want_rc), output: $out"
  fi
}

run_case same-workflows          t1     t1     false 0 ""
run_case main-changed-workflows  t1     t2     false 1 "::error::main changed .github/workflows after aaaaaaaaaaaa"
run_case dry-run-only-warns      t1     t2     true  0 "::warning::main changed .github/workflows"
run_case workflows-added-later   absent t2     false 1 "::error::main changed .github/workflows"
run_case both-without-workflows  absent absent false 0 ""
run_case github-error-fails      t1     t1     false 1 "::error::Could not read .github at aaaaaaaa" 500

echo
echo "$pass passed, $fail failed"
test "$fail" -eq 0
