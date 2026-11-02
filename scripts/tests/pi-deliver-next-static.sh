#!/usr/bin/env bash
# Runs the "next-static" lines exactly as both deliver.yml copies ship them
# (between their BEGIN/END markers) against stub docker and aws commands, and
# checks that:
#
# - only images with "next-static" and a bucket publish, to s3://<bucket>/_next/static/;
# - .css and .js upload with explicit Content-Types and the immutable Cache-Control;
# - nothing passes --delete;
# - an empty static directory or malformed static-buckets stops the job.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }

mkdir -p "$work/bin"
# docker cp writes a fake .next/static tree unless EMPTY_STATIC is set.
cat >"$work/bin/docker" <<'STUB'
#!/usr/bin/env bash
echo "docker $*" >>"$CALLS"
case "$1" in
  create) echo cid123 ;;
  cp) test -n "${EMPTY_STATIC:-}" && exit 0
      mkdir -p "$3/chunks" "$3/css" "$3/media"
      echo x >"$3/chunks/main-abc.js"; echo x >"$3/css/app-def.css"; echo x >"$3/media/font-1.woff2"; echo x >"$3/media/logo.png" ;;
esac
STUB
# The push role may only list and put (no GetObject): anything but s3 sync fails.
cat >"$work/bin/aws" <<'STUB'
#!/usr/bin/env bash
echo "aws $*" >>"$CALLS"
test "$1 $2" = "s3 sync" || { echo "push role cannot: aws $1 $2" >&2; exit 254; }
STUB
chmod +x "$work/bin/docker" "$work/bin/aws"

built='[{"name":"web","ref":"r.example/pi-membl/web@sha256:1","arch":"amd64"},{"name":"app","ref":"r.example/pi-membl/app@sha256:2","arch":"amd64"},{"name":"worker","ref":"r.example/pi-membl/worker@sha256:3","arch":"amd64"}]'
images='[{"name":"web","next-static":"/app/apps/web/.next/static"},{"name":"app","next-static":"/app/apps/app/.next/static/"},{"name":"worker"}]'

run() { # dir, static-buckets, extra env...
  local dir="$1" buckets="$2"; shift 2
  : >"$dir/calls"
  env PATH="$work/bin:$PATH" CALLS="$dir/calls" BUILT="$built" IMAGES_INPUT="$images" STATIC_BUCKETS="$buckets" "$@" \
    bash -euo pipefail -c '. "$1"' _ "$dir/ns.sh" >"$dir/out" 2>&1
}

for wf in .depot/workflows/deliver.yml .github/workflows/deliver.yml; do
  tag="$(dirname "$(dirname "$wf")")"; tag="${tag#.}"
  dir="$work/$tag"; mkdir -p "$dir"
  awk '/# BEGIN next-static/{on=1} on{print} /# END next-static/{on=0}' "$repo_root/$wf" | sed -E 's/^ {10}//' >"$dir/ns.sh"
  grep -q 'END next-static' "$dir/ns.sh" || { bad "$tag: next-static markers not found"; continue; }

  if run "$dir" '{"web":"web-bkt","app":"app-bkt","worker":"w-bkt"}'; then
    calls="$dir/calls"
    if grep -q 'docker cp cid123:/app/apps/web/.next/static/\. ' "$calls" && grep -q 'docker cp cid123:/app/apps/app/.next/static/\. ' "$calls"; then ok "$tag: copies each next-static dir (trailing slash tolerated)"; else bad "$tag: docker cp paths: $(grep 'docker cp' "$calls")"; fi
    if ! grep -q 'worker' "$calls"; then ok "$tag: image without next-static is skipped"; else bad "$tag: worker touched"; fi
    if grep -q 's3 sync .* s3://web-bkt/_next/static/ .*--include \*.css --content-type text/css --cache-control public, max-age=31536000, immutable' "$calls"; then ok "$tag: css typed and immutable"; else bad "$tag: css sync: $(grep 'web-bkt' "$calls" | head -3)"; fi
    if grep -q 's3 sync .* s3://app-bkt/_next/static/ .*--include \*.js --content-type text/javascript' "$calls"; then ok "$tag: js typed"; else bad "$tag: js sync"; fi
    if grep -q 's3 sync .* s3://app-bkt/_next/static/ --only-show-errors --exclude \*.css .*--exclude \*.txt --cache-control' "$calls"; then ok "$tag: remainder synced once"; else bad "$tag: remainder sync"; fi
    if ! grep -q -- '--delete' "$calls"; then ok "$tag: never --delete"; else bad "$tag: --delete used"; fi
    if grep -q 's3 sync .* s3://web-bkt/_next/static/ .*--include \*.woff2 --content-type font/woff2' "$calls"; then ok "$tag: woff2 typed"; else bad "$tag: woff2 sync"; fi
  else
    bad "$tag: happy path failed: $(cat "$dir/out")"
  fi

  if run "$dir" '{"web":"web-bkt"}'; then
    if grep -q 'app/.next' "$dir/calls"; then bad "$tag: app published without a bucket"; elif grep -q 'warning::app' "$dir/out"; then ok "$tag: image without a bucket warns and skips"; else bad "$tag: no warning for app"; fi
  else bad "$tag: missing bucket should not fail: $(cat "$dir/out")"; fi

  if run "$dir" '{"web":"web-bkt"}' EMPTY_STATIC=1; then bad "$tag: empty static passed"; else ok "$tag: empty static dir stops"; fi
  if run "$dir" '["web-bkt"]'; then bad "$tag: malformed static-buckets passed"; else ok "$tag: malformed static-buckets stops"; fi
done

echo "$pass passed, $fail failed"
test "$fail" = 0
