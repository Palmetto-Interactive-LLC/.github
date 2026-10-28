# Palmetto-Interactive-LLC/.github

Organization defaults, plus the CI/CD standard every active repo follows (Linear PAL-1022).

## CI/CD standard

1. Every GitHub Actions job runs on our Marsh runners: `runs-on: [self-hosted, daytona]`, or `[self-hosted, daytona, large]` for image builds and heavy tests. Not GitHub-hosted, not CodeBuild. Marsh runners are x86_64 Daytona sandboxes today. The Palmetto fleet moves to Daytona v2 arm64 later, and only the runner label changes then.
2. ECS hosts are Graviton, so images are `linux/arm64`. On the x86_64 Marsh runners they build with `docker buildx` under QEMU (`docker/setup-qemu-action`).
3. `main` takes changes only through pull requests: 0 required approvals, no bypass actors, squash-only, auto-merge on, branch deleted on merge.
4. One set of workflows, defined here:
   - Pull requests and `main`: `pi-checks` (quick checks, secrets, dependencies, workflow lint).
   - Deployable repos, on merge to `main`: build the arm64 image, push to ECR by full git SHA, deploy staging, wait for it to be stable, cut the release `vYYYY.MM.DD.N`, deploy the same digest to prod. No manual step.

The fast path is: push a branch, open a PR, let `pi-checks` pass, auto-merge.

## Reusable workflows

This repository is public, so any repository in the organization can call these workflows without extra Actions access settings.

| Workflow | Purpose |
|---|---|
| `.github/workflows/pi-checks.yml` | Checks. Jobs `quick`, `secrets`, `deps`, `actions`, and the aggregate `pi-checks`. |
| `.github/workflows/pi-deliver.yml` | Build, ECR, staging, release, prod. |

Reusable workflows run on the caller's runners, so every job takes `runs-on` from an input. Each input is a JSON array of labels, read with `fromJSON`, and defaults to the Marsh fleet. Callers normally pass nothing:

| Input | Workflow | Default |
|---|---|---|
| `runner-small` | `pi-checks`, `pi-deliver` (deploy jobs) | `'["self-hosted","daytona"]'` |
| `runner-build` | `pi-deliver` (image build) | `'["self-hosted","daytona","large"]'` |

The fleet is defined in pi-platform `k8s/apps/marsh/20-configmap-palmetto.yaml` (snapshots `pi-runner-{default,large}-v9`). When the Palmetto fleet moves to Daytona v2 arm64, change the defaults here and nothing else.

The Marsh runner group (`daytona`) is limited to selected private repositories. A repo not in that group queues forever, so add it to the group before adopting the workflows. Public repositories are not allowed in the group; they use a GitHub-hosted runner with a TODO.

Workflow templates for new repositories are in `workflow-templates/` (Actions, New workflow, organization section).

### Pinning

Pin to the full commit SHA of a release tag, with the tag in a comment:

```yaml
uses: Palmetto-Interactive-LLC/.github/.github/workflows/pi-checks.yml@<40-char sha> # v1
```

`v1` moves only by a new tag on this repository; bump the SHA in callers on purpose.

## pi-checks

Inputs: `runner-small`, `stack` (`node` default, `python`, `go`, `rust`, `tofu`, `docs`), `working-directory`, `node-version`, `python-version`, `go-version` (empty reads `go.mod`), `rust-toolchain`, `tofu-version`, and `install-command`, `lint-command`, `typecheck-command`, `test-command`, `build-command`. A command input replaces the stack default for that phase; `-` skips the phase.

Stack defaults run only what the repo defines. For `node` the package manager comes from the lockfile and a phase is skipped when `package.json` has no script by that name.

Jobs:

- `quick`: install, lint, typecheck, test, build.
- `secrets`: gitleaks over full history (uses the repo's `.gitleaks.toml` if present).
- `deps`: osv-scanner. Fails on CRITICAL (CVSS 9.0 and up), annotates HIGH (7.0 to 8.9).
- `actions`: actionlint and zizmor at high severity over `.github/workflows`.
- `pi-checks`: succeeds only if all four succeeded.

**The required status check is `pi-checks / pi-checks`.** GitHub names a called job `<caller job id> / <called job>`, so the caller job id must be `pi-checks` (the template does this).

Rulesets: `rulesets/main.json` still lists the legacy contexts (`build-test`, `lint`, `secrets-scan`, `sast`, `deps-scan`, `iac-scan`, `actions-lint`) that `pi-standard-ci.yml` and `pi-standard-security.yml` produce. A repo switches its required check to `pi-checks / pi-checks` when it adopts the template.

## pi-deliver

Inputs: `app`, `cluster` (both required), `runner-build`, `runner-small`, plus:

| Input | Default | Meaning |
|---|---|---|
| `images` | `[{"name":"web","dockerfile":"Dockerfile","context":"."}]` | JSON list of `{name, dockerfile, context[, container]}`. ECR repository is `<app>/<name>`. |
| `services` | `[app]` | JSON list of service app names. Each runs as `<service>-<env>`. |
| `container-name` | `web` | Main container. The image named `web` goes here. |
| `environments` | `["staging","prod"]` | Deployed in order. The release is cut after the first. |
| `migrate-command` | none | Pre-deploy migration (below). |
| `migrate-secrets` | none | `{"<env>": {"ENV_VAR": "<secret name or ARN>"}}` for the migration task only. |
| `stable-timeout-minutes` | `15` | Per environment. |

The calling job needs `permissions: { contents: write, id-token: write }` and must not use a GitHub `environment:` (it changes the OIDC subject the deploy role trusts).

Repository variables, set by pi-platform: `ECS_DEPLOY_ENABLED` (`true` turns delivery on; otherwise the workflow does nothing), `PI_PLATFORM_IMAGE_PUSH_ROLE_ARN` (ECR push, build job), `ECS_DEPLOY_ROLE_ARN` (deploy jobs).

Flow:

1. Build. For each image: skip if `<app>/<name>:<full sha>` already exists in ECR, otherwise `docker buildx build --platform linux/arm64 --provenance=false --sbom=false` (QEMU on x86_64 runners) and push. The job fails if the image in ECR is not arm64. The digest is read back from ECR and promoted to every environment.
2. Per environment, in order: register a new task-definition revision per service with the image digest and `SENTRY_RELEASE=<release tag>`, run the migration if set, `update-service`, then wait. A container gets the new image if its name matches the image's container or its current image is that ECR repository.
3. The wait is a poll, not `aws ecs wait services-stable`: it requires the PRIMARY deployment of the revision just registered to reach `COMPLETED` with running equal to desired, and fails on `FAILED` (circuit-breaker rollback). ALB health is part of that. Default 15 minutes.
4. After the first environment is stable: compute `vYYYY.MM.DD.N` (UTC day, `N` continues from existing tags; a re-run of the same commit reuses its tag), create the annotated tag and the GitHub Release (notes plus image digests).
5. Prod gets the same digest. A failed or unstable staging stops the run before prod.

Concurrency is one delivery per repository (`pi-deliver-<repo>`), never cancelled while running. A newer pending run replaces an older pending one.

### Migrations hook

`migrate-command` runs once per environment, before `update-service`, as a one-off ECS task from the new revision: the main container with its command overridden, on the service's own capacity provider (bridge network, EC2). A plain string runs under `sh -c`; a JSON array is used as the exact command (for images without a shell). The task must exit 0 or the environment is not rolled. It inherits the task definition's environment and Secrets Manager wiring. `migrate-secrets` registers an extra revision of the same family with additional secret references for that task only; the services keep the other revision, and the task execution role must be able to read those secrets.

The deploy role (pi-platform `ecs-deploy-role`) needs `ecs:RunTask`, `ecs:DescribeTasks` and `ecs:StopTask` scoped to the app's task-definition families and cluster for this to work, and `iam:PassRole` for the app's task and execution roles (already granted). Without them the migration step fails with an access error and nothing is deployed.
