# Security Policy

## Supported versions

| Version | Supported |
|---------|-----------|
| 0.1.x   | Yes       |

## Reporting a vulnerability

Please **do not** open a public GitHub issue for security vulnerabilities.

Instead, report them via GitHub's private [Security Advisories](https://github.com/OmerTDK/dbt-credit-risk/security/advisories/new) feature:

1. Go to the **Security** tab of this repository.
2. Click **Report a vulnerability**.
3. Fill in the details: affected version, reproduction steps, and your assessment of impact.

You will receive an acknowledgement within 5 business days. We aim to have a fix or mitigation available within 30 days for confirmed vulnerabilities.

## Scope

This package contains only SQL/Jinja macros and integration-test seeds. There are no network calls, no credential handling, and no executable binaries. The primary security surface is:

- **SQL injection via macro arguments**: macro arguments are inserted into Jinja templates. Callers who pass user-controlled strings as column or relation names should sanitize inputs before passing them to these macros.
- **Dependency vulnerabilities**: `dbt-core`, `dbt-duckdb`, and other dev dependencies. Dependabot monitors these automatically.
