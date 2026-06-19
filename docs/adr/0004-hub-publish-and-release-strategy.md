# ADR-0004: Hub Publication and Release Strategy

**Date:** 2026-06-19
**Status:** Accepted

## Context

Phase 4 targets publication of `dbt-credit-risk` to the dbt Package Hub so any analytics
engineer can install it via `packages.yml` without referencing a private GitHub URL. Four
concrete decisions required tradeoffs:

1. **Semver starting point** — v0.1.0 vs v1.0.0
2. **Hub publication mechanism** — direct Hub registry PR vs. git-ref install as interim
3. **`require-dbt-version` floor** — how far back to support
4. **Hardest design decision for the "design decisions" writeup** — which ADR-documented
   choice is the most valuable signal

## Decision

### 1. Semver: v0.1.0

The package has three macro families, a full integration-test harness, and adapter support
for DuckDB (CI-tested) and BigQuery (adapter helpers written and tested at the platform level).
The output schemas are stable but this is a first public release — callers should expect
additive changes in 0.x minor versions and breaking changes only in 1.0.0+.

v1.0.0 is reserved for a future point when the package has real external users, a changelog
of shipped versions, and a track record of schema stability. Starting at 1.0.0 implies a
public commitment to backward compatibility that this first release cannot yet honor.

### 2. Hub publication: git-ref install (interim), dbt Hub PR as the follow-on

dbt Hub publication (https://hub.getdbt.com/) requires:

1. The GitHub repository is **public**.
2. A release tag exists (e.g. `v0.1.0`).
3. A PR is opened to https://github.com/dbt-labs/dbt-hub-utils or the hub-registry repo,
   adding a YAML entry pointing to the GitHub repo and the release tag.

The repository is currently **private**. This is a blocker for Hub listing. Until the repo
is made public and the Hub PR is merged, callers install via:

```yaml
packages:
  - git: "https://github.com/OmerTDK/dbt-credit-risk"
    revision: v0.1.0
```

The git-ref install is already documented in the README and works identically to a Hub
install for callers with network access to GitHub. This phase ships the tag and the Hub
publishing documentation; the actual Hub PR is a manual step contingent on the repo going
public (see "Manual steps required" below).

### 3. `require-dbt-version: ">=1.8.0"`

The macros use:
- `exceptions.raise_compiler_error()` — available since dbt 0.19
- `ref()` and `source()` as first-class Jinja objects passed to macros — available since dbt 1.0
- No `dbt_utils` or other package dependencies — zero dependency risk
- No features from dbt 1.9+ that would push the floor higher

`require-dbt-version` has existed since dbt 0.13.0. The floor is set at 1.8 because it
represents the oldest dbt-core release still in wide active use (released May 2024, now 2+
years old). Supporting 1.7 would require testing against an additional release; supporting
older versions is unnecessary given the adoption curve.

The ceiling is deliberately left open (`>=1.8.0` not `>=1.8.0,<2.0.0`) because the macros
use no private dbt internals — there is no reason to expect them to break in dbt 2.x.

### 4. Hardest design decision: the gap-continuity guard in `roll_rate_matrix`

The single hardest design decision in the package is the **gap-continuity guard** in
`roll_rate_matrix`: using an `INNER JOIN` rather than a `LEFT JOIN` in the `at_risk_denominator`
CTE to exclude loans that have no row in the active population for the next observation period.

The intuition is that a loan whose next period does not exist in the data cannot "transition"
anywhere — it left the at-risk pool before the next period began (paid off, written off,
missing data). Including it in the denominator overstates the at-risk count and artificially
deflates all transition rates for that period-from_bucket pair.

The bug is completely invisible in a naively constructed test: with a LEFT JOIN, the row
still exists in the result with a correct-looking count, just higher than it should be.
Only a test with a specific inactive loan that is expected to be excluded from the denominator
(like `loan_c` in the seed, which goes inactive in February) can catch it — which is exactly
what `assert_gap_exclusion.sql` does.

## Alternatives considered

### v1.0.0 as starting version

Rejected. Implies a backward-compatibility promise the package is not yet in a position to
make with zero external users. 0.x correctly signals "stable but evolving."

### Submit Hub PR immediately (before repo is public)

Not possible. Hub listing requires a public repo. Attempting to submit early produces a 404
when Hub tries to fetch the repo metadata.

### `require-dbt-version: ">=1.0.0"`

Unnecessarily broad. 1.0 is 5+ years old (released 2022); supporting it would require testing
against a release most users have long since abandoned. 1.8 is the practical floor for a
package targeting current analytics engineers.

### Left join in `at_risk_denominator`

Rejected (not just in the ADR, but in the code). A LEFT JOIN includes loans whose next period
is absent, inflating the at-risk denominator and deflating transition rates. The bug is subtle
because the overall structure of the output — one row per (period, from_bucket, to_bucket) —
looks identical with either join; only the count values differ. The test `assert_gap_exclusion`
was written specifically to catch this class of error.

## Consequences

**Easier:**
- The `require-dbt-version` floor prevents cryptic errors for callers on ancient dbt versions;
  the error message from dbt core ("this package requires dbt >= 1.8.0") is more actionable
  than a Jinja compilation error.
- Tagging at v0.1.0 establishes a stable install reference before any Hub PR is submitted;
  callers who install via git ref now get pinned behavior.
- The Hub PR (manual step) is well-documented and can be submitted by any repo maintainer once
  the repo is made public.

**Harder:**
- Until the repo is made public and the Hub PR is merged, the "Install from Hub" path does
  not exist — only git-ref install. This is documented explicitly in the README to set
  expectations.
- Making the repo public is an irreversible action (even after making it private again,
  any public-period forks or clones persist). The decision requires deliberate sign-off.

## Manual steps required after this PR merges

1. **Make the GitHub repo public** — Settings → General → Change repository visibility.
2. **Submit the Hub PR** — Fork https://github.com/dbt-labs/hub.getdbt.com, add a YAML
   file for `credit_risk` pointing to this repo and the `v0.1.0` tag, and open a PR.
   Alternatively, use https://hub.getdbt.com/register to trigger the automated flow.
3. **Update the README install snippet** — Replace the git-ref install instructions with
   the Hub snippet once the listing is live:
   ```yaml
   packages:
     - package: omertdk/credit_risk
       version: [">=0.1.0", "<0.2.0"]
   ```
