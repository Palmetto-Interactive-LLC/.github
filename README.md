# Palmetto-Interactive-LLC/.github

Organization defaults and the shared CI/CD workflows (Linear PAL-1022).

## CI/CD standard

Everything runs on Depot CI (owner decision 2026-11-01; no AWS CodeBuild, no GitHub-hosted runners). Workflows live in `.depot/workflows/` and are plain GitHub Actions YAML run on Depot's sandboxes (`runs-on: depot-ubuntu-24.04`). Images build with `depot build` (project `3bhs1495zg`), `linux/amd64`.

1. `main` takes changes only through pull requests: 0 required approvals, no bypass actors, squash-only, auto-merge on, branch deleted on merge.
2. **Pull request:** `pi-checks` in light mode. Install, lint, typecheck, quick unit tests, a secret scan of the PR's commits, and actionlint when workflows changed. Docs-only changes exit fast. Target: under 2 minutes.
3. **Merge to `main`:** `deliver.yml` (staging) builds the image, pushes it to ECR by full git SHA and deploys **staging** only.
4. **Production:** the manual **Create Release** workflow (`pi-release.yml`), run by hand from `main`. Heavy gates, staging-digest check, ECR CRITICAL scan, tag `vYYYY.MM.DD.N`, then the same digest to prod. **Prod never deploys automatically.**

A failed default-branch delivery or release posts a non-paging alert to incident.io (the `incident_io_url` secret; it must use underscores, because Depot rejects hyphenated secret names on reusable workflows).

## Reusable workflows

| Workflow | Purpose |
|---|---|
| `.depot/workflows/pi-checks.yml` | Checks. `mode: pr` (default) is light; `mode: release` is the heavy gate set. Jobs `changes`, `title`, `quick`, `secrets`, `deps`, `actions`, and the aggregate `pi-checks`. `title` (PR mode) requires a Conventional Commits PR title (`feat(scope): subject`); on a merge queue run it checks the queue commit's first line. A caller that wants the merge queue checked lists `merge_group:` in its own `on:`. |
| `.depot/workflows/deliver.yml` | The ECS engine. `mode: staging` (default) builds and deploys staging; `mode: release` promotes to prod. |
| `.depot/workflows/pi-release.yml` | Create Release: heavy gates (`pi-checks`), then `deliver.yml` in release mode. `deploy: false` runs the gates and cuts a tag only. |
| `.github/workflows/deliver.yml` | GitHub Actions copy of the ECS engine for repos moving off Depot CI (membl pilot, PAL-1022). Same modes and inputs, plus `runs-on` (default `membl`), `environment` and `staging-url`. AWS auth is GitHub OIDC; the deploy job runs in a GitHub environment. A staging deploy shows `staging-url` (a full `https://` URL, normally pi-platform's first `hostnames.staging`) as the `staging` environment URL; empty shows none, and a release never sets one. The URL doesn't change the OIDC subject (`environment:<name>`). The Depot copy gets no environment: its roles trust only the Depot subject for `refs/heads/main` (pi-platform `ecs-deploy-role`), and its header warns that `environment:` changes the subject. A repo moves to this copy and split deploy roles to get a staging URL. In release mode it also takes `digest`: a rollback to a digest listed in a published GitHub Release of the repository (any other digest is refused before AWS is touched; no build, no new tag, no staging check, the ECR scan gate still runs; only the services that release deployed, which its notes list (older releases deployed only `<app>`); tested by `scripts/tests/pi-deliver-rollback-target.sh`). The Depot copy stays for repos still on Depot CI. Call it with `uses: Palmetto-Interactive-LLC/.github/.github/workflows/deliver.yml@<40-char sha>`. |
| `.github/workflows/preview.yml` | Preview slots (ADR 0017), generalized from pi-client-portal. Runs on the preview manager's `repository_dispatch` (`preview-up`, `preview-renew`, `preview-down`), builds the PR's commit, deploys slot `<app>-preview-<k>` with the preview role and records a GitHub Deployment in `preview-<PR number>` at `https://<app>-<k>.<preview-domain>/`. `preview-down` scales the slot to 0 and marks that environment's Deployments inactive. See [preview.yml](#previewyml). Deployments are named per PR (`preview-<PR>`); pi-client-portal's own workflow names them per slot (`preview-<k>`), so a repo uses one scheme or the other, never both. |

Callers live in the app's `.depot/workflows/` and pin by full commit SHA:

```yaml
uses: Palmetto-Interactive-LLC/.github/.depot/workflows/pi-release.yml@<40-char sha>
```

Branch refs are not supported; bump the SHA in callers on purpose. `pi-release` pins `pi-checks` and `deliver` by SHA itself (a nested call cannot name its own commit), so a change to those two needs a follow-up PR that bumps the pins in `pi-release.yml`.

The old GitHub Actions versions (`pi-checks`, `pi-deliver`, `pi-release`, `pi-standard-*`, `ai-review`) and the workflow templates were removed; they ran on CodeBuild runners. Pinned callers of the old SHAs still resolve but have no runner.

## deliver.yml

Each ECS app has a thin `deliver.yml` (push to main, staging) and `release.yml` (workflow_dispatch, prod) that call it:

```yaml
uses: Palmetto-Interactive-LLC/.github/.depot/workflows/deliver.yml@<40-char sha>
```

- `mode: staging`: `depot build --platform linux/amd64`, push to ECR by SHA, read the architecture back from the image, deploy staging from the service's live task definition revision (secret guard, runtimePlatform from the image, staging wake), wait for the PRIMARY deployment to reach COMPLETED. A circuit-breaker or alarm rollback fails the run and says which.
- `mode: release`: no build. Requires the image for the head of main and staging running that exact digest, gates on the ECR CRITICAL scan, cuts `vYYYY.MM.DD.N`, deploys the same digest to prod with the migration. Only the head of main is delivered; to roll back, revert on main and release again.
- AWS auth is Depot's OIDC token (`identity.depot.dev`) through `aws-actions/configure-aws-credentials`. The IAM roles trust the Depot sub for the repo on `main`, set up in pi-platform (`github.depot_ci`).
- Repo variables are Depot CI variables (`depot ci vars add NAME --value V --repo owner/repo`): `ECS_DEPLOY_ENABLED`, `PI_PLATFORM_IMAGE_PUSH_ROLE_ARN`, `ECS_DEPLOY_ROLE_ARN`, `ECS_SERVING_SECRETS`. They do not resolve inside the shared (external) workflow, so the caller passes them as inputs: `deploy-enabled: ${{ vars.ECS_DEPLOY_ENABLED }}`, `push-role-arn`, `deploy-role-arn`, `serving-secrets`. GitHub Actions variables are not visible to Depot.
- The snippets under `scripts/tests/` run the marked blocks of this file against fakes.

## preview.yml

The preview manager in membl-runner core owns the slot lease. On a PR open or a new head it takes or renews a slot and dispatches `preview-up` (or `preview-renew`); on close it releases the lease and dispatches `preview-down`. The workflow never runs on `pull_request`: the preview role trusts only `environment:preview`, and pi-platform gives that environment a main-only branch policy, so a PR's own run can't get the role. `repository_dispatch` runs the caller from the default branch, so a PR can't change what deploys it.

Inputs: `app` (required), `service` (ECR suffix, default `web`), `cluster` (default `pi-platform-prod`), `preview-domain` (default `preview.palmettointeractive.com`), `runs-on` (default `membl`), `dockerfile`, `context`, `platforms` (default `linux/amd64`), `secret-keys` (pi-platform `previews.secret_keys`; the slot may serve only those and `DATABASE_URL`), `push-role-arn`, `deploy-role-arn` (fallback; the preview environment's `ECS_DEPLOY_ROLE_ARN` wins). Outputs: `url`, `digest`.

```yaml
name: Preview
on:
  repository_dispatch:
    types: [preview-up, preview-renew, preview-down]
permissions: {}
jobs:
  preview:
    permissions: { contents: read, deployments: write, id-token: write, pull-requests: read }
    uses: Palmetto-Interactive-LLC/.github/.github/workflows/preview.yml@<40-char sha>
    with:
      app: <project>
      secret-keys: '["SESSION_SECRET"]'
      push-role-arn: ${{ vars.PI_PLATFORM_IMAGE_PUSH_ROLE_ARN }}
```

Prerequisites in pi-platform: `previews = { slots = N, service, secret_keys }` and `github.split_deploy_roles` with a `preview` environment (`deploy_branches = ["main"]`), and the repository registered with the preview manager.

### PostHog deploy annotation (optional)

A successful prod deploy posts an annotation to PostHog (`POST /api/projects/<id>/annotations/`) so releases show on every chart. It is skipped silently unless both are set, and it never fails a deploy (`continue-on-error`).

- Project id: the `posthog-project-id` input (Depot CI variable `POSTHOG_PROJECT_ID`).
- Key: secret `POSTHOG_ANNOTATION_KEY`, a PostHog personal API key scoped to `annotation:write` only. Callers pass it explicitly (`secrets: { POSTHOG_ANNOTATION_KEY: ... }`).

### Image scan gate

The release job of `deliver.yml` reads `describe-image-scan-findings` for each digest staging is running. It polls until the scan is `COMPLETE` (or `ACTIVE` under enhanced scanning). Then:

- Every CRITICAL finding is printed as id, package and version, and the severity counts go in the job summary.
- A CRITICAL finding fails the release (nothing is tagged or deployed to prod) unless its id is in the allowlist and the entry hasn't expired.
- `FAILED`, an unknown status, or a scan still pending at the timeout fails the job.
- `UNSUPPORTED_IMAGE` (scratch or distroless images with no OS package database) is a warning, not a failure.
- A reused image keeps the scan from its first push. Basic scanning doesn't rescan.

The allowlist is a JSON file in the caller repository (`scan-allowlist` input, default `.github/ecr-scan-allowlist.json`):

```json
{
  "allow": [
    {
      "id": "CVE-2026-12345",
      "reason": "Not reachable: the image never runs the affected binary. Tracked in PAL-1234.",
      "expires": "2026-12-31"
    }
  ]
}
```

`id` is the finding name ECR reports (the CVE id). `reason` is required. `expires` (UTC date, inclusive) is optional but expected: once it passes, the entry stops counting and the job warns about it. Keep entries few and dated, and fix the base image when a patched one exists. Check first with `aws ecr describe-image-scan-findings --repository-name <app>/<name> --image-id imageTag=<sha>`.

### Migrations hook

`migrate-command` runs once per environment (staging on a merge, prod on a release), before `update-service`, as a one-off ECS task from the new revision: the main container with its command overridden, on the service's own capacity provider. A plain string runs under `sh -c`; a JSON array is used as the exact command (for images without a shell). The task must exit 0 or the environment is not rolled. `migrate-secrets` registers an extra revision of the same family with additional secret references for that task only; the services keep the other revision, and the task execution role must be able to read those secrets. That migration-only revision is deregistered when the migration step ends.

**Secret guard.** Before registering a serving revision, the deploy fails if any secret name contains `MIGRATOR` as a word (`DATABASE_MIGRATOR_URL`), or if a name is not in pi-platform's declared list for that service (`serving-secrets` input). Without the list only the migrator check runs, with a warning. If the guard fails, the service already runs a revision with that secret: move it to a clean revision (`aws ecs update-service --task-definition <clean revision>`), then deploy again. Tested by `scripts/tests/pi-deliver-secret-guard.sh`.

The deploy role (pi-platform `ecs-deploy-role`) needs `ecs:DeregisterTaskDefinition`, `ecs:RunTask`, `ecs:DescribeTasks` and `ecs:StopTask` scoped to the app's families and cluster, and `iam:PassRole` for the app's task and execution roles.

## pi-checks

Inputs: `mode` (`pr` default, or `release`), `stack` (`node` default, `python`, `go`, `rust`, `tofu`, `docs`), `working-directory`, `node-version`, `python-version`, `go-version` (empty reads `go.mod`), `rust-toolchain`, `tofu-version`, and the phase commands `install-command`, `lint-command`, `typecheck-command`, `quick-test-command` (pull requests), `test-command` (the full suite, release only), `build-command` (release only), `release-gate-command` (extra heavy gate, release only). A command input replaces the stack default for that phase; `-` skips the phase.

Stack defaults run only what the repo defines. For `node` the package manager comes from the lockfile and a phase is skipped when `package.json` has no script by that name. On a pull request the quick test is the `test:quick` script, else `test:unit`, else nothing.

- `changes`: classifies the diff. Docs-only skips every other job.
- `quick`: install, lint, typecheck, quick tests (release: full tests, build, `release-gate-command`).
- `secrets`: gitleaks over the PR's own commits (full history on a release).
- `deps` (release only): osv-scanner, fails on CRITICAL, annotates HIGH.
- `actions`: actionlint over `.github/workflows` and `.depot/workflows` (Depot labels are declared self-hosted), only when workflows changed; zizmor on a release.
- `pi-checks`: succeeds when every job above succeeded or was skipped.

The caller job id decides the required status context, for example `CI / pi-checks / pi-checks` for a caller job `pi-checks` in a workflow named `CI`.

## pi-release (Create Release)

The caller workflow is named exactly **Create Release** and has one trigger, `workflow_dispatch`, with optional inputs `dry_run` (gates only: no tag, no deploy) and `requested_by`. It takes the `pi-checks` inputs plus the `deliver.yml` inputs, `deploy` (default `true`), and the Depot CI variables as inputs: `deploy-enabled`, `push-role-arn`, `deploy-role-arn`, `serving-secrets`, `posthog-project-id`, `notify-role-arn`, `app-url`. Jobs: `mode` (refuses anything but a dispatch on `main`), `gates`, `deliver`, `tag` (only with `deploy: false`: gates, then tag and GitHub Release, for repos with no ECS service such as pi-platform), `notify` (always, except a dry run; invokes the `pi-release-notify` Lambda through `notify-role-arn`, whose role must trust the Depot OIDC subject; skipped with a warning when empty), and `alert` (incident.io when gates or tag fail). The calling job needs `permissions: { contents: write, id-token: write }` and no `environment:`.

Outputs: `release_url`, `release_tag`, `app_url`, `image_digest`, `run_url`.

Put the full suite in `test-command` and any IaC, policy, cost or integration gate in `release-gate-command`. Keep `quick-test-command` to seconds.
