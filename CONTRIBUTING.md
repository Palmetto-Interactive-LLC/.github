# Contributing

## Issues And Beads

Use GitHub issues for external intake that is safe to share in the repository.
The supported human-facing types are **Bug**, **Feature**, **Epic**, and
**Issue**; see [docs/ISSUE-TRACKING.md](docs/ISSUE-TRACKING.md) for the exact
GitHub label to Beads type mapping.

Use Beads (`bd`) for durable implementation tracking inside the repo. When a
GitHub issue becomes implementation work, link the GitHub issue from the Beads
record or mention the Beads ID in the pull request. Do not edit
`.beads/issues.jsonl` directly.

Never place vulnerability details, secrets, customer data, or private incident
notes in public GitHub issues.

## Pull Requests

1. Start from an issue or Beads item when possible.
2. Create a branch from `main`.
3. Use signed commits.
4. Keep history linear and changes focused.
5. Run the relevant tests, linters, builds, or document why the change is
   docs-only.
6. Complete the pull request template.
7. Wait for required checks and the configured AI reviewer.

`CODEOWNERS` documents ownership only. It is not intended to be a required
approval gate in the default no-human-review setup.

## Local Beads Commands

```bash
bd ready
bd show <id>
bd update <id> --claim
bd close <id> --reason="Completed"
```

Use GitHub issues for user-facing intake and Beads for work that must survive
handoff between local sessions.
