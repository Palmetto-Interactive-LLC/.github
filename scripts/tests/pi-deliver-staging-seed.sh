#!/usr/bin/env bash
# Exercise the actual shipped hook against a fake gh and reviewed caller file.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
workflow="$repo_root/.depot/workflows/deliver.yml"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
for marker in staging-seed staging-seed-guard; do
  awk "/# BEGIN ${marker}\$/{on=1} on{print} /# END ${marker}\$/{on=0}" "$workflow" \
    | sed -E 's/^ {10}//' >"$work/$marker.sh"
  grep -q "END $marker" "$work/$marker.sh"
done
mkdir -p "$work/caller/scripts"
cat >"$work/caller/scripts/seed.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test "$MEMBL_STAGING_DELIVERY_LEASE" = "deliver-fixture/repo"
test "$MEMBL_STAGING_DELIVERY_SOURCE_SHA" = "$GITHUB_SHA"
test "$MEMBL_STAGING_BUILT_IMAGES" = "$IMAGES"
test "$MEMBL_STAGING_CLUSTER" = "fixture-cluster"
test "$MEMBL_STAGING_APP" = "fixture-app"
printf '%s\n' called >> "$CALLS"
test "${HOOK_FAIL:-false}" != true
EOF
cat >"$work/run.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cd "$GITHUB_WORKSPACE"
gh() { test "$1" = api; echo "$CURRENT_HEAD"; }
timeout() {
  test "$1" = --signal=INT && test "$2" = --kill-after=150s && test "$3" = 1200s
  shift 3
  "$@"
}
export -f gh timeout
. "$HOOK_SNIPPET"
EOF
sha=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
run_case() {
  local label="$1" want="$2" mode="$3" ref="$4" script="$5" head="$6" fail="${7:-false}" rc=0
  : >"$work/calls"
  MODE="$mode" DEPLOY_ENV="$mode" GITHUB_REF="$ref" GITHUB_SHA="$sha" \
  GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=1 GITHUB_REPOSITORY=fixture/repo \
  GITHUB_WORKSPACE="$work/caller" STAGING_SEED_SCRIPT="$script" STAGING_SEED_ROLE=fixture-seed-role \
  CURRENT_HEAD="$head" IMAGES='[{"name":"web","digest":"sha256:fixture"}]' \
  CLUSTER=fixture-cluster APP=fixture-app CALLS="$work/calls" HOOK_FAIL="$fail" \
  HOOK_SNIPPET="$work/staging-seed.sh" bash "$work/run.sh" >"$work/output" 2>&1 || rc=$?
  if test "$want" = pass; then test "$rc" = 0 && test "$(cat "$work/calls")" = called
  else test "$rc" != 0; fi
  echo "ok   $label"
}
run_case 'reviewed staging caller runs under inherited lease' pass staging refs/heads/main ./scripts/seed.sh "$sha"
run_case 'production never runs a seed' stop prod refs/heads/main ./scripts/seed.sh "$sha"
run_case 'feature branch denied' stop staging refs/heads/feature ./scripts/seed.sh "$sha"
run_case 'stale main denied' stop staging refs/heads/main ./scripts/seed.sh bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
run_case 'shell text is not a script path' stop staging refs/heads/main './scripts/seed.sh;touch-owned' "$sha"
run_case 'traversal denied' stop staging refs/heads/main ./scripts/../scripts/seed.sh "$sha"
run_case 'seed failure stops subsequent deployment' stop staging refs/heads/main ./scripts/seed.sh "$sha" true
ln -s seed.sh "$work/caller/scripts/link.sh"
run_case 'symlink seed denied' stop staging refs/heads/main ./scripts/link.sh "$sha"
# Guard is a no-op for existing callers, including production with a hook input.
MODE=staging STAGING_SEED_SCRIPT='' STAGING_SEED_ROLE='' HAS_STAGING=false bash "$work/staging-seed-guard.sh"
MODE=release STAGING_SEED_SCRIPT=./scripts/seed.sh STAGING_SEED_ROLE='' HAS_STAGING=false bash "$work/staging-seed-guard.sh"
if MODE=staging STAGING_SEED_SCRIPT=./scripts/seed.sh STAGING_SEED_ROLE=role HAS_STAGING=false bash "$work/staging-seed-guard.sh" >/dev/null 2>&1; then exit 1; fi
python3 - "$workflow" <<'PY'
from pathlib import Path
import re, sys
import yaml
p=Path(sys.argv[1]); source=p.read_text(); wf=yaml.load(source, Loader=yaml.BaseLoader)
assert wf['permissions'] == {}
assert wf['concurrency'] == {'group':'deliver-${{ github.repository }}','cancel-in-progress':'false'}
for name in ['staging-seed-script','staging-seed-role-arn','staging-seed-config']:
    assert wf['on']['workflow_call']['inputs'][name]['default'] == ''
steps=wf['jobs']['deploy']['steps']
seed=[s for s in steps if s['name'] in ['Checkout the reviewed staging seed caller','Configure AWS credentials through Depot OIDC (staging seed)','Run the reviewed staging seed caller']]
assert len(seed)==3 and all(s['if']=="env.MODE == 'staging' && inputs.staging-seed-script != ''" for s in seed)
assert steps.index(seed[-1]) < next(i for i,s in enumerate(steps) if s['name']=='Configure AWS credentials through Depot OIDC (ECS deploy)')
assert steps.index(seed[-1]) < next(i for i,s in enumerate(steps) if s['name']=='Register task definitions with the new image')
assert wf['jobs']['deploy']['permissions']=={'contents':'read','id-token':'write'}
for match in re.finditer(r'uses:\s+([^\s]+)(.*)',source):
    assert re.search(r'@[a-f0-9]{40}$',match[1]) and '#' in match[2]
secret_names = ['staging_neon_api_key','staging_temporal_api_key','staging_temporal_codec_keyring']
for name in secret_names:
    assert wf['on']['workflow_call']['secrets'][name]['required']=='false'
for job in wf['jobs'].values():
    assert not any('MEMBL_STAGING_' in k for k in job.get('env',{}))
    for step in job.get('steps',[]):
        injected = {k for k in step.get('env',{}) if k.startswith('MEMBL_STAGING_')}
        if injected:
            assert step['name']=='Run the reviewed staging seed caller'
            assert injected=={'MEMBL_STAGING_SEED_CONFIG','MEMBL_STAGING_NEON_API_KEY','MEMBL_STAGING_TEMPORAL_API_KEY','MEMBL_STAGING_TEMPORAL_CODEC_KEYRING'}
assert seed[-1]['env']['MEMBL_STAGING_SEED_CONFIG']=='${{ inputs.staging-seed-config }}'
# Remove only the explicitly gated additions: every prior parsed source byte
# (including shell bodies) must then equal current protected main exactly.
import copy, subprocess
# Compare to the immutable pre-hook contract. origin/main contains this hook
# after merge, so a mutable baseline would make main reject its own additions.
baseline_ref='0ab85924b9912af8650d7761e269382d66d4c3dd'
baseline=yaml.load(subprocess.check_output(['git','show',baseline_ref+':.depot/workflows/deliver.yml'],text=True),Loader=yaml.BaseLoader)
prior=copy.deepcopy(wf)
for name in ['staging-seed-script','staging-seed-role-arn','staging-seed-config']:
    del prior['on']['workflow_call']['inputs'][name]
for name in secret_names:
    del prior['on']['workflow_call']['secrets'][name]
mode=prior['jobs']['guard']['steps'][0]
for name in ['STAGING_SEED_SCRIPT','STAGING_SEED_ROLE','HAS_STAGING']:
    del mode['env'][name]
mode['run']=re.sub(r'  # BEGIN staging-seed-guard\n.*?  # END staging-seed-guard\n','',mode['run'],flags=re.S)
# YAML removes the common leading indentation from run blocks.
mode['run']=re.sub(r'# BEGIN staging-seed-guard\n.*?# END staging-seed-guard\n','',mode['run'],flags=re.S)
prior['jobs']['deploy']['steps']=[s for s in prior['jobs']['deploy']['steps'] if s['name'] not in {item['name'] for item in seed}]
normal=next(s for s in prior['jobs']['deploy']['steps'] if s['name']=='Configure AWS credentials through Depot OIDC (ECS deploy)')
assert normal['with'].pop('unset-current-credentials')=="${{ inputs.mode == 'staging' && inputs.staging-seed-script != '' }}"
assert prior==baseline,'existing default/prod/non-Membl semantics changed'
print('ok   optional defaults, production parity, secret scope, OIDC pins, least privilege and ordering')
PY
