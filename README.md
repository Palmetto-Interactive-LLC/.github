# Palmetto-Interactive-LLC/.github

Organization defaults, plus the CI/CD standard every active repo follows (Linear PAL-1022).

## CI/CD standard

1. Every GitHub Actions job runs on the org's AWS CodeBuild ARM runner (project `pi-actions` in account 490600801675, paid from AWS credits; owner decision 2026-10-28): `runs-on: codebuild-pi-actions-${{ github.run_id }}-${{ github.run_attempt }}`. That is arm1.small (2 vCPU, 4 GiB, Amazon Linux 2023, arm64, Docker). Append `-arm-3.0-medium` for arm1.medium. Not GitHub-hosted (`ubuntu-24.04-arm`, `ubuntu-latest`), not Marsh/Daytona. The exceptions below are the only ones. The reusable workflows hold the label in one place (see "Reusable workflows"); infrastructure is `pi-platform` `docs/codebuild-github-runners.md`.
2. ECS hosts are Graviton, so images are `linux/arm64`. They build natively on the ARM runner with `docker buildx build --platform linux/arm64`. No QEMU.
3. `main` takes changes only through pull requests: 0 required approvals, no bypass actors, squash-only, auto-merge on, branch deleted on merge.
4. One set of workflows, defined here. Heavy work happens only on a production release:
   - **Pull request:** `pi-checks` in light mode. Install, lint, typecheck, quick unit tests, a secret scan of the PR's commits, and actionlint when workflows changed. Docs-only changes exit fast. No full test suite, build, dependency audit or image build. Target: under 2 minutes. AI Review is manual only (`workflow_dispatch` with a PR number).
   - **Merge to `main`:** `pi-deliver` builds the arm64 image, pushes it to ECR by full git SHA and deploys **staging** only. It never touches prod and cuts no release.
   - **Production:** the manual **Create Release** workflow (`pi-release`), run by hand from `main` and triggered by nothing else. It runs the heavy gates, checks that staging runs the image being released, gates on ECR's CRITICAL scan of that exact digest, cuts the release `vYYYY.MM.DD.N`, and deploys the same digest to prod with the migration. Rollback is an input of the same workflow. **Prod never deploys automatically.**

The fast path is: push a branch, open a PR, let `pi-checks` pass, auto-merge. Staging follows the merge. When staging looks right, run Create Release.

### Exceptions

Two exceptions to the runner and architecture rules. Each repo listed here keeps the exception to the jobs named, and everything else follows the standard.

| Exception | Repos | Scope |
|---|---|---|
| GitHub-hosted macOS and Windows runners (`macos-15`, `windows-latest`) | `boardwalk`, `Sweetgrass` (public) | Only these jobs; every other job in both repos runs on CodeBuild. `boardwalk` builds `Boardwalk.app` in `build.yml` on `macos-15`. `Sweetgrass` builds its npm release binaries in the `build` matrix of `release.yml` on `macos-15` (darwin-arm64, darwin-x64) and `windows-latest` (win32-x64); its linux-x64 leg runs on CodeBuild `-ubuntu-7.0-medium`. CodeBuild has macOS only on reserved Mac fleets, and its Windows image has no MSVC C++ build tools. Hosted runners are free for public repos, so the $0 Actions budget does not stop them. |

A new exception needs a reason that a Linux ARM runner cannot satisfy (an Apple or Windows toolchain, or a non-ARM deploy target). Add the repo to this table in the same pull request that introduces it.

## Reusable workflows

This repository is public, so any repository in the organization can call these workflows without extra Actions access settings.

| Workflow | Purpose |
|---|---|
| `.github/workflows/pi-checks.yml` | Checks. `mode: pr` (default) is light; `mode: release` is the heavy gate set. Jobs `changes`, `quick`, `secrets`, `deps`, `actions`, and the aggregate `pi-checks`. |
| `.github/workflows/pi-deliver.yml` | The ECS engine. `mode: staging` (default): build and deploy staging. `mode: release` and `mode: rollback`: prod, workflow_dispatch from main only. |
| `.github/workflows/pi-release.yml` | Create Release: heavy gates, then `pi-deliver` in release (or rollback) mode. `deploy: false` runs the gates and cuts a tag only. |

Reusable workflows run on the caller's runners, so every job takes `runs-on` from an input. Each input is a JSON array of labels, read with `fromJSON`. The defaults `["codebuild"]` and `["codebuild-medium"]` expand to the CodeBuild label for the caller's run (`codebuild-pi-actions-<run_id>-<run_attempt>`, plus `-arm-3.0-medium`). Callers pass nothing and do not override it:

| Input | Workflow | Default |
|---|---|---|
| `runner-small` | `pi-checks`, `pi-deliver` (deploy jobs), `pi-release` | `'["codebuild"]'` (arm1.small) |
| `runner-build` | `pi-deliver` (image build), `pi-release` | `'["codebuild-medium"]'` (arm1.medium) |

To change runners, change the two defaults and the `runs-on` expressions here and nothing else. `pi-deliver` fails the build job if the runner is not arm64.

Cost: CodeBuild bills per minute from AWS credits (arm1.small $0.0034, arm1.medium $0.007), up to 60 concurrent builds per size (extra builds queue), with a $50/month AWS Budget alarm (`pi-platform-codebuild-monthly`). The organization's GitHub Actions budget is $0 with stop-on-limit (owner, 2026-10-29), so a private-repo job on a GitHub-hosted runner does not run; GitHub-hosted runners are only for the public-repo exceptions above. `pi-checks` caches package downloads (npm, pnpm, yarn, pip, cargo, and Go through `setup-go`) keyed on the lockfile. Keep your own `install-command` and `test-command` overrides lean for the same reason.

Workflow templates for new repositories are in `workflow-templates/` (Actions, New workflow, organization section).

### Pinning

Pin to the full commit SHA of a release tag, with the tag in a comment:

```yaml
uses: Palmetto-Interactive-LLC/.github/.github/workflows/pi-checks.yml@<40-char sha> # v1
```

`v1` moves only by a new tag on this repository; bump the SHA in callers on purpose.

## pi-checks

Inputs: `mode` (`pr` default, or `release`), `runner-small`, `stack` (`node` default, `python`, `go`, `rust`, `tofu`, `docs`), `working-directory`, `node-version`, `python-version`, `go-version` (empty reads `go.mod`), `rust-toolchain`, `tofu-version`, and the phase commands `install-command`, `lint-command`, `typecheck-command`, `quick-test-command` (pull requests), `test-command` (the full suite, release only), `build-command` (release only), `release-gate-command` (extra heavy gate, release only). A command input replaces the stack default for that phase; `-` skips the phase.

Stack defaults run only what the repo defines. For `node` the package manager comes from the lockfile and a phase is skipped when `package.json` has no script by that name. On a pull request the quick test is the `test:quick` script, else `test:unit`, else nothing.

**Pull request (light)**:

- `changes`: classifies the diff. Docs-only (Markdown, `docs/`, licenses, images) skips every other job.
- `quick`: install, lint, typecheck, quick tests.
- `secrets`: gitleaks over the PR's own commits (uses the repo's `.gitleaks.toml` if present).
- `actions`: actionlint, only when `.github/workflows` or `.github/actions` changed.
- `pi-checks`: succeeds when every job above succeeded or was skipped.

**Release** (`mode: release`, called by `pi-release`): `quick` runs the full `test-command`, the build and `release-gate-command`; `secrets` scans full history; `deps` runs osv-scanner (fails on CRITICAL, CVSS 9.0 and up, annotates HIGH, 7.0 to 8.9); `actions` adds zizmor at high severity. Custom runner labels such as `daytona` are flagged as unknown by actionlint.

Pull-request callers trigger on `pull_request` only. Pushes to `main` do not run `pi-checks`.

**The required status check is `pi-checks / pi-checks`.** GitHub names a called job `<caller job id> / <called job>`, so the caller job id must be `pi-checks` (the template does this).

Rulesets: `rulesets/main.json` still lists the legacy contexts (`build-test`, `lint`, `secrets-scan`, `sast`, `deps-scan`, `iac-scan`, `actions-lint`) that `pi-standard-ci.yml` and `pi-standard-security.yml` produce. A repo switches its required check to `pi-checks / pi-checks` when it adopts the template.

## pi-deliver

Inputs: `app`, `cluster` (both required), `mode`, `runner-build`, `runner-small`, plus:

| Input | Default | Meaning |
|---|---|---|
| `mode` | `staging` | `staging`, `release` or `rollback` (below). `release` and `rollback` refuse to run unless the event is `workflow_dispatch` on `refs/heads/main`. |
| `images` | `[{"name":"web","dockerfile":"Dockerfile","context":"."}]` | JSON list of `{name, dockerfile, context[, container]}`. ECR repository is `<app>/<name>`. |
| `services` | `[app]` | JSON list of service app names. Each runs as `<service>-<env>`. |
| `container-name` | `web` | Main container. The image named `web` goes here. |
| `has-staging` | `true` | `false` for an app with no staging services (Membl, Marsh): a merge to `main` only builds and pushes the image, nothing deploys, and a release skips the staging-digest check. Prod still deploys only from a manual release. |
| `migrate-command` | none | Pre-deploy migration (below). |
| `migrate-secrets` | none | `{"<env>": {"ENV_VAR": "<secret name or ARN>"}}` for the migration task only. |
| `stable-timeout-minutes` | `15` | Per environment. |
| `scan-allowlist` | `.github/ecr-scan-allowlist.json` | Caller-repo file of accepted CRITICAL findings (below). A missing file is an empty allowlist. |
| `scan-timeout-minutes` | `10` | How long to wait for ECR's scan of each image. |

The calling job needs `permissions: { contents: write, id-token: write }` (the release job asks for `contents: write`, and a called workflow cannot ask for more than its caller) and must not use a GitHub `environment:` (it changes the OIDC subject the deploy role trusts).

**Build cache.** Each staging build writes its layers to `<app>/<name>:buildcache-<sha>` (registry cache, `mode=max`) and reads the newest `buildcache-*` tag of that repository. Tags are immutable, so the cache gets a new tag every build. Those images count against the ECR lifecycle's 300-image limit and age out with it. A missing cache or a failed cache push never fails the build.

Repository variables, set by pi-platform: `ECS_DEPLOY_ENABLED` (`true` turns delivery on; otherwise the workflow does nothing), `PI_PLATFORM_IMAGE_PUSH_ROLE_ARN` (ECR push, build job), `ECS_DEPLOY_ROLE_ARN` (deploy jobs).

**Modes**

1. `staging` (the push-to-main caller). Build: for each image, skip if `<app>/<name>:<full sha>` already exists in ECR, otherwise `docker buildx build --platform linux/arm64 --provenance=false --sbom=false` natively on the arm64 runner and push. The job fails if the image in ECR is not arm64. The digest is read back from ECR. Then deploy staging: register a new task-definition revision per service with the image digest and `SENTRY_RELEASE=sha-<12 chars>` (staging deploys are not releases), run the migration if set, `update-service`, then wait. A container gets the new image if its name matches the image's container or its current image is that ECR repository. No scan gate, no tag, no prod.
2. `release` (from `pi-release`, after the gates). No build: the image `<app>/<name>:<head sha>` must already be in ECR, or the run fails with "let the staging deploy finish first". The run then requires every service's staging task definition to be running exactly that digest, gates on ECR's scan of the digest (below), cuts the annotated tag `vYYYY.MM.DD.N` and the GitHub Release in its own job (`N` continues from existing tags; a re-run of the same commit reuses its tag), and only then deploys the same digest to prod with the migration.
3. `rollback` (from `pi-release` with `rollback_to` set). See "Rollback".

The wait is a poll, not `aws ecs wait services-stable`: it requires the PRIMARY deployment of the revision just registered to reach `COMPLETED` with running equal to desired, and fails on `FAILED` (circuit-breaker rollback). ALB health is part of that. Default 15 minutes.

**Stale runs never deploy.** Each deploy job first compares the run's commit with the current head of its branch (GitHub API). If they differ (a re-run of an old run, or an older run that was queued behind a newer one), every later step is skipped, with a notice, and the job succeeds. The only way to deploy an older commit is a rollback.

**Rollback.** A rollback redeploys an image that is already in ECR to one environment. Nothing is built, scanned, migrated or released, and it runs from the `main` ref. It is an input of the Create Release workflow (the template declares both):

```yaml
  workflow_dispatch:
    inputs:
      rollback_to:
        description: "Leave empty to release the head of main. To roll back instead: a release tag (vYYYY.MM.DD.N) or full commit SHA on main."
        required: false
        default: ""
      rollback_env:
        description: "Environment to roll back (used only with rollback_to)."
        type: choice
        options: [staging, prod]
        default: prod
```

Run it from Actions, Create Release, Run workflow on `main`, or `gh workflow run "Create Release" -R <org>/<repo> --ref main -f rollback_to=v2026.10.28.2 -f rollback_env=prod`. The target must be a release tag or commit on `main`, and its image `<app>/<name>:<sha>` must still exist in ECR (the lifecycle policy may have expired old ones). The service rolls to that image's digest, the head check is skipped, and `SENTRY_RELEASE` is the target's tag (`sha-<12 chars>` if it has none). Database migrations are not reversed, and a rollback skips the migration step, so only roll back to a build whose schema the current database still satisfies.

**Rolling forward** after a rollback: a merge to `main` redeploys staging, and a new Create Release (no inputs) puts the head back on prod. A staging-only roll forward is `gh workflow run "PI Deliver" -R <org>/<repo> --ref main`.

Concurrency is one delivery per repository (`pi-deliver-<repo>`), never cancelled while running. A newer pending run replaces an older pending one.

### Image scan gate

The release job of `pi-deliver` (mode `release`) reads `describe-image-scan-findings` for each digest staging is running. It polls every 10 seconds until the scan is `COMPLETE` (or `ACTIVE` under enhanced scanning), up to `scan-timeout-minutes`. Then:

- Every CRITICAL finding is printed as id, package and version, and the severity counts go in the job summary.
- A CRITICAL finding fails the release (nothing is tagged or deployed to prod) unless its id is in the allowlist and the entry hasn't expired.
- `FAILED`, an unknown status, or a scan still pending at the timeout fails the job.
- `UNSUPPORTED_IMAGE` (scratch or distroless images with no OS package database) is a warning, not a failure, because there is nothing to gate on.
- A reused image keeps the scan from its first push. Basic scanning doesn't rescan, so findings published since then show up on the next build of a new commit.

The allowlist is a JSON file in the caller repository:

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

`id` is the finding name ECR reports (the CVE id). `reason` is required. `expires` (UTC date, inclusive) is optional but expected: once it passes, the entry stops counting and the job warns about it. Keep entries few and dated, and fix the base image when a patched one exists.

A release fails if the staging image has an unaccepted CRITICAL finding. Check first with `aws ecr describe-image-scan-findings --repository-name <app>/<name> --image-id imageTag=<sha>`.

### Migrations hook

`migrate-command` runs once per environment (staging on a merge, prod on a release), before `update-service`, as a one-off ECS task from the new revision: the main container with its command overridden, on the service's own capacity provider (bridge network, EC2). A plain string runs under `sh -c`; a JSON array is used as the exact command (for images without a shell). The task must exit 0 or the environment is not rolled. It inherits the task definition's environment and Secrets Manager wiring. `migrate-secrets` registers an extra revision of the same family with additional secret references for that task only; the services keep the other revision, and the task execution role must be able to read those secrets.

The deploy role (pi-platform `ecs-deploy-role`) needs `ecs:RunTask`, `ecs:DescribeTasks` and `ecs:StopTask` scoped to the app's task-definition families and cluster for this to work, and `iam:PassRole` for the app's task and execution roles (already granted). Without them the migration step fails with an access error and nothing is deployed.

## pi-release (Create Release)

Reusable `pi-release.yml`; the caller workflow is named exactly **Create Release** and has one trigger, `workflow_dispatch` (template `workflow-templates/pi-release.yml`). It takes the union of the `pi-checks` and `pi-deliver` inputs, plus `deploy` (default `true`). Jobs: `mode` (refuses anything but a dispatch on `main`; picks release or rollback from `rollback_to`), `gates` (`pi-checks` in release mode), `deliver` (`pi-deliver` in release or rollback mode), and `tag` (only with `deploy: false`: the gates, then the release tag and GitHub Release, for repositories with no ECS service such as pi-platform).

**Dispatch inputs** (the caller declares them; the template does): `sha` (optional full commit SHA on `main`; default is the head; the commit's already-built image is what ships, so the SHA must be on `main` and its image must exist in ECR, and a non-head SHA skips the stale-run guard and the staging-digest check because it is a deliberate choice). **A non-head SHA can be released only while its `.github/workflows` matches main's.** GitHub refuses the run's `GITHUB_TOKEN` a tag (via `git/refs` or `/releases`) on a commit whose workflows differ from main's, with 403 "Resource not accessible by integration", because that token never holds the `workflows` permission. The `mode` job checks this before the gates and stops with "main changed .github/workflows after <sha>"; a dry run only warns. Release main's head instead. Rollbacks create no tag and are not affected. Test: `scripts/tests/pi-release-workflows-check.sh`., `requested_by` (free text), `dry_run` (boolean: only the heavy gates and the ECR scan, no tag, no deploy, no notification), `rollback_to` and `rollback_env`.

**Outputs** of the reusable workflow: `release_url`, `release_tag`, `app_url` (the `app-url` input, else the `APP_URL` repository variable), `image_digest`, `run_url`. A final `notify` job always runs (except on a dry run), sets those outputs and invokes the `pi-release-notify` Lambda for Slack #client-releases through the role in the org variable `PI_RELEASE_NOTIFY_ROLE_ARN`. It is skipped with a warning when the variable is empty, and its steps cannot fail the release.

Put the full suite in `test-command` and any IaC, policy, cost or integration gate in `release-gate-command`. Keep `quick-test-command` to seconds.
