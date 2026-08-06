# Issue Tracking

Linear is the durable source of truth for planning and implementation work.
GitHub issues are the repository-facing intake surface for work that is safe to
share. Internal work may begin directly in Linear; accepted GitHub intake
should be linked to a Linear issue before implementation starts.

## Workspace Routing

- Use the Palmetto Interactive workspace for internal product, platform, and
  portfolio work.
- Use the Palmetto Interactive Clients workspace for client delivery work.
- Assign each Linear issue to the correct project and associate that project
  with the initiative governing its implementation repository.
- Give every initiative a one-sentence outcome description and list or link
  every GitHub repository it governs.

## Work Item Types

| Human type | GitHub form | GitHub label | Use when |
| --- | --- | --- | --- |
| Bug | `bug_report.yml` | `type:bug` | Existing behavior is reproducibly wrong. |
| Feature | `feature_request.yml` | `type:feature` | A new capability or meaningful behavior change is requested. |
| Epic | `epic.yml` | `type:epic` | The work is large enough to break into a Linear project or parent issue with children. |
| Issue | `issue.yml` | `type:issue` | The work is valid but not yet clearly a bug, feature, or epic. |

GitHub labels classify public intake. Linear owns implementation state,
priority, ownership, project placement, initiative alignment, relationships,
and closeout.

## Triage Convention

1. Search GitHub and the correct Linear workspace for existing work.
2. Confirm a GitHub issue has exactly one `type:*` label.
3. Create or update the Linear issue in the correct workspace and project.
4. Link the GitHub issue from Linear and add the Linear issue to the pull
   request.
5. Use Linear parent/child and blocking relationships for dependent work.
6. Keep Linear status, owner, priority, and project current through closeout.
7. Close the Linear issue only after implementation and verification are
   complete.

Do not put secrets, vulnerability details, customer data, or private incident
notes in public GitHub issues or ordinary Linear issues. Use private security
advisories and appropriately access-controlled coordination for vulnerability
reports.
