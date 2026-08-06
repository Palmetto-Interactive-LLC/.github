# Contributing

## Issues And Work Tracking

Use GitHub issues for external intake that is safe to share in the repository.
The supported human-facing types are **Bug**, **Feature**, **Epic**, and
**Issue**; see [docs/ISSUE-TRACKING.md](docs/ISSUE-TRACKING.md) for the triage
and routing conventions.

Use Linear for durable planning and implementation tracking. Internal product
work belongs in the Palmetto Interactive workspace; client delivery belongs in
the Palmetto Interactive Clients workspace. When a GitHub issue becomes
implementation work, link it to the Linear issue and assign that issue to the
correct project. Keep that project associated with its governing initiative.

Never place vulnerability details, secrets, customer data, or private incident
notes in public GitHub issues.

## Pull Requests

1. Start from a Linear issue or linked GitHub issue when possible.
2. Create a branch from `main`.
3. Use signed commits.
4. Keep history linear and changes focused.
5. Run the relevant tests, linters, builds, or document why the change is
   docs-only.
6. Complete the pull request template.
7. Wait for required checks and the configured AI reviewer.

`CODEOWNERS` documents ownership only. It is not intended to be a required
approval gate in the default no-human-review setup.

Keep the Linear issue's status, owner, priority, project, initiative, and pull
request links current throughout implementation and closeout.
