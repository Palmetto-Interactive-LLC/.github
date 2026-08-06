# Security Policy

## Reporting A Vulnerability

Please do not open a public GitHub issue for suspected vulnerabilities.

Use GitHub private vulnerability reporting for this repository, or contact the
maintainer through the private channel documented for the generated project.
Include affected versions, reproduction steps, impact, and any known exposure.

## Supported Versions

This template tracks the default branch. Generated projects should replace this
section with their own supported version policy.

| Version | Supported |
| --- | --- |
| `main` | Yes |

## Coordinating Fixes

Security reports may be tracked privately in GitHub Security Advisories and in
an appropriately access-controlled Linear issue for implementation
coordination. Public GitHub issues are appropriate for non-sensitive bugs and
feature requests. Do not copy exploit details, secrets, customer data, or
private advisory content into public issues or ordinary Linear issues.

## Baseline Expectations

- Use signed commits for protected branches.
- Keep deploy credentials out of GitHub secrets when OIDC is available.
- Use GitHub issue forms for public intake and Linear for durable internal task
  tracking.
- Rotate any exposed credential immediately and document the incident privately.
