#!/usr/bin/env bash
# Runs the "tag-number" lines exactly as .github/workflows/deliver.yml ships
# them (between its BEGIN/END markers) against a fake gh api, and checks the
# tag a release cuts: the build's choice when it is free or already on this
# commit, else the next free number of today.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$repo_root/.github/workflows/deliver.yml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

awk '/# BEGIN tag-number/{on=1} on{print} /# END tag-number/{on=0}' "$workflow" \
  | sed -E 's/^ {10}//' >"$work/tag.sh"
grep -q 'END tag-number' "$work/tag.sh" || { echo "FAIL: markers not found in $workflow"; exit 1; }

# Fake gh api. TAGGED is the commit the build's tag points at ("" if the tag
# does not exist); TODAY_TAGS the numbers of today's tags (space separated).
cat >"$work/gh" <<'GH'
#!/usr/bin/env bash
shift # api
path="$1"
case "$path" in
  */commits/*) test -n "$TAGGED" || exit 1; echo "$TAGGED" ;;
  */git/matching-refs/tags/*)
    prefix="${path##*/tags/}"
    printf '['; sep=''; for n in $TODAY_TAGS; do printf '%s{"ref":"refs/tags/%s%s"}' "$sep" "$prefix" "$n"; sep=,; done; echo ']' ;;
  *) echo "unexpected gh api $path" >&2; exit 2 ;;
esac
GH
chmod +x "$work/gh"

today="v$(date -u +%Y.%m.%d)."
pass=0 fail=0
# name, VERSION, TAGGED, TODAY_TAGS, expected version
run_case() {
  local got out="$work/out"
  : >"$out"
  if PATH="$work:$PATH" GITHUB_OUTPUT="$out" RUNNER_TEMP="$work" GITHUB_REPOSITORY=org/app GITHUB_SHA=aaa \
    VERSION="$2" TAGGED="$3" TODAY_TAGS="$4" bash -euo pipefail "$work/tag.sh" >/dev/null 2>&1; then
    got="$(sed -n 's/^version=//p' "$out" | tail -n 1)"
  else
    got=error
  fi
  if test "$got" = "$5"; then
    pass=$((pass + 1)); echo "ok   $1"
  else
    fail=$((fail + 1)); echo "FAIL $1: got '$got', want '$5'"
  fi
}

run_case "free tag: kept" "${today}3" "" "1 2" "${today}3"
run_case "tag already on this commit (re-run): kept" "${today}3" aaa "1 2 3" "${today}3"
run_case "tag taken by another release: next free" "${today}3" bbb "1 2 3" "${today}4"
run_case "yesterday's tag taken: today's next" "v2000.01.01.1" bbb "" "${today}1"

echo "${pass} passed, ${fail} failed"
test "$fail" -eq 0
