#!/usr/bin/env bash
# Runs the "alert-post" lines exactly as .github/workflows/deliver.yml ships them
# (between its BEGIN/END markers) against a fake curl, and checks that a lost
# alert fails the job with its status and body, and that no part of the secret
# URL reaches the log, even when the response echoes it.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$repo_root/.github/workflows/deliver.yml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

awk '/# BEGIN alert-post/{on=1} on{print} /# END alert-post/{on=0}' "$workflow" \
  | sed -E 's/^ {10}//' >"$work/post.sh"
grep -q 'END alert-post' "$work/post.sh" || { echo "FAIL: markers not found in $workflow"; exit 1; }

id="01ALERTSOURCEID"
token="not-a-real-token-value"
url="https://alerts.example.test/v2/alert_events/http/${id}?token=${token}"

mkdir "$work/bin"
cat >"$work/bin/curl" <<'FAKE'
#!/usr/bin/env bash
out=""
while test $# -gt 0; do
  case "$1" in -o) out="$2"; shift 2 ;; -d) printf '%s' "$2" >"$WORK/payload.json"; shift 2 ;; *) shift ;; esac
done
if test "$FAKE_CODE" = "fail"; then printf '000'; exit 7; fi
printf '%b' "$FAKE_BODY" >"$out"
printf '%s' "$FAKE_CODE"
FAKE
chmod +x "$work/bin/curl"

export GITHUB_SHA=abcdefabcdefabcd GITHUB_SERVER_URL=https://s GITHUB_REPOSITORY=o/app GITHUB_RUN_ID=1

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1: $2"; }

run_case() { # name, url, code, body, expected exit, expected output (substring)
  local out status=0 shown
  out="$(WORK="$work" PATH="$work/bin:$PATH" ALERT_URL="$2" FAKE_CODE="$3" FAKE_BODY="$4" APP=app MODE=release REPO=o/app \
    bash -euo pipefail "$work/post.sh" 2>&1)" || status=$?
  # The runner hides add-mask lines and applies them. Everything else is the log.
  shown="$(grep -v '^::add-mask::' <<<"$out" || true)"
  if test "$status" -ne "$5"; then bad "$1" "exit $status, want $5: $out"; return; fi
  if [[ "$shown" != *"$6"* ]]; then bad "$1" "output lacks '$6': $shown"; return; fi
  if [[ "$shown" == *"$token"* || "$shown" == *"$id"* || "$shown" == *"alerts.example.test"* ]]; then
    bad "$1" "a secret reached the log: $shown"; return
  fi
  if grep -v '^::error::\|^::notice::' <<<"$shown" | grep -q '^::'; then bad "$1" "a stray workflow command: $shown"; return; fi
  ok "$1"
}

run_case "2xx is sent" "$url" 202 '{"status":"success"}' 0 "Alert sent."
run_case "no secret does not alert" "" 202 '' 0 "Not alerting."
run_case "422 fails with status and body" "$url" 422 '{"errors":[{"code":"invalid"}]}' 1 'HTTP 422. Response: {"errors":[{"code":"invalid"}]}'
run_case "an echoed URL is scrubbed" "$url" 422 "bad request to ${url}" 1 "bad request to [redacted]"
run_case "an echoed token is scrubbed" "$url" 401 "token ${token} rejected" 1 "token [redacted] rejected"
run_case "an echoed source id is scrubbed" "$url" 404 "no source ${id}" 1 "no source [redacted]"
run_case "a body cannot start a workflow command" "$url" 500 'oops\n::notice::forged' 1 "HTTP 500"
run_case "curl failing is reported" "$url" fail '' 1 "HTTP 000"

long="$(printf 'x%.0s' $(seq 3000))"
out="$(WORK="$work" PATH="$work/bin:$PATH" ALERT_URL="$url" FAKE_CODE=500 FAKE_BODY="$long" APP=app MODE=release REPO=o/app \
  bash -euo pipefail "$work/post.sh" 2>&1 || true)"
kept="$(grep '^::error::' <<<"$out" | tr -cd x | wc -c | tr -d ' ')"
if test "$kept" = 1000; then ok "a long body is cut at 1000"; else bad "a long body is cut at 1000" "kept $kept"; fi

# Every field the HTTP source requires is in what actually gets posted.
WORK="$work" PATH="$work/bin:$PATH" ALERT_URL="$url" FAKE_CODE=202 FAKE_BODY='' APP=app MODE=release REPO=o/app \
  bash -euo pipefail "$work/post.sh" >/dev/null 2>&1 || true
if jq -e '.title and .deduplication_key and .status == "firing"' "$work/payload.json" >/dev/null; then
  ok "the payload is posted with its required fields"
else
  bad "the payload is posted with its required fields" "$(cat "$work/payload.json")"
fi

echo "pi-deliver-alert-post: $pass passed, $fail failed"
test "$fail" -eq 0
