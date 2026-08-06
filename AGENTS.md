# Agent Instructions

## Work Tracking

Linear is the durable source of truth for planning and implementation work.
Use GitHub issues only for repository-facing intake that is safe to share.

- Route internal product and platform work to the Palmetto Interactive Linear
  workspace.
- Route client delivery work to the Palmetto Interactive Clients Linear
  workspace.
- Assign every implementation issue to the correct Linear project.
- Give every Linear initiative a one-sentence outcome description and list or
  link every GitHub repository it governs.
- Keep each Linear project associated with the initiative that governs its
  implementation repository.
- Link pull requests and GitHub issues to their Linear issue, and update the
  Linear status, owner, priority, and relationships as work changes.
- Keep secrets, vulnerability details, customer data, and private incident
  notes out of public GitHub issues and ordinary Linear issues.

## Non-Interactive Shell Commands

**ALWAYS use non-interactive flags** with file operations to avoid hanging on confirmation prompts.

Shell commands like `cp`, `mv`, and `rm` may be aliased to include `-i` (interactive) mode on some systems, causing the agent to hang indefinitely waiting for y/n input.

**Use these forms instead:**
```bash
# Force overwrite without prompting
cp -f source dest           # NOT: cp source dest
mv -f source dest           # NOT: mv source dest
rm -f file                  # NOT: rm file

# For recursive operations
rm -rf directory            # NOT: rm -r directory
cp -rf source dest          # NOT: cp -r source dest
```

**Other commands that may prompt:**
- `scp` - use `-o BatchMode=yes` for non-interactive
- `ssh` - use `-o BatchMode=yes` to fail instead of prompting
- `apt-get` - use `-y` flag
- `brew` - use `HOMEBREW_NO_AUTO_UPDATE=1` env var

## Review Guidelines

Treat this repository as security-sensitive production software. Reviews should prioritize correctness, least privilege, release integrity, and whether the repository stays within the paid GitHub Team baseline without silently depending on GHAS or Enterprise-only features.

- Flag any secret, token, account ID, ARN, real cluster name, or static cloud credential committed to the repo as P0.
- Flag any `AWS_ACCESS_KEY_ID` or `AWS_SECRET_ACCESS_KEY` usage for deploys as P0; cloud deploy authentication should use OIDC role/federation flows.
- Flag any unpinned GitHub Action (`uses:` not pinned to a full 40-character commit SHA with a version comment) as P0.
- Flag broad IAM/cloud permissions such as `iam:*`, `*:*`, wildcard resources without a documented rationale, or production trust policies that accept every repo ref as P0.
- Flag workflows that omit top-level `permissions: {}` or grant broader job permissions than the job uses as P1.
- Flag any use of `pull_request_target` for model-driven review or code execution as P0.
- Flag missing tests or verification for new scripts, rulesets, workflow behavior, infrastructure changes, or release changes as P1.
- Flag direct human-review requirements that would deadlock a solo developer, such as required approving reviews or required CODEOWNERS review, as P1.
- Flag production deployment paths that bypass protected `main`, immutable GitHub Releases with `v*` tags, environment branch/tag policies, or required status checks as P1.
- Flag logging of secrets, PII, cloud tokens, OIDC tokens, or full GitHub event payloads as P1.
