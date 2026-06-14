# ADR-0001: Roll-Rate Macro API, Input Contract, and Gap-Continuity Guard

**Date:** 2026-06-14
**Status:** Accepted

## Context

The roll-rate matrix is the keystone analytic for this package. It computes delinquency
state-transition probabilities from a caller-supplied loan-performance relation. Extracting it
from the credit-data-platform required three concrete design decisions:

1. **How to parameterize the macro** — flat named arguments vs. a config dict
2. **How to validate the input contract** — compile-time Jinja guards vs. dbt tests vs. runtime SQL assertions
3. **How to handle gap-exclusion** — the case where a loan is absent from the active population in
   one period (paid off, inactive, or missing data) and must not be counted in the denominator of
   the preceding period

Each of these has a non-obvious tradeoff.

## Decision

### 1. Flat named arguments, no dict

The macro signature uses flat named keyword arguments:

```jinja
{% macro roll_rate_matrix(
    relation,
    loan_id_col,
    period_col,
    ...
    segment_cols=[],
    period_length_months=1,
    minimum_cell_count=10
) %}
```

### 2. Three-layer validation

- **Layer 1 — Jinja compile-time guards**: `exceptions.raise_compiler_error()` for every
  required argument, for the `segment_cols` string-vs-list confusion, for numeric bounds, and for
  reserved-column-name collisions. These fire at `dbt parse` time, before any SQL is generated.
- **Layer 2 — Runtime SQL contract assertions**: Three CTEs (`grain_violation_count`,
  `null_period_count`, `negative_balance_count`) plus a `contract_assertions` CTE that uses
  division-by-zero to surface violated invariants. Fired via a `cross join contract_assertions`
  in `active_periods`.
- **Layer 3 — Post-model dbt singular tests**: Five tests shipped in `integration_tests/tests/`
  that assert structural invariants on the macro's output (row-for-row match against a
  hand-verified expected seed — including absolute balance columns — no negative self-transitions,
  probabilities sum to one, no null from_bucket, gap exclusion denominator holds).

### 3. Self-join on next_period_date for gap-continuity

`at_risk_denominator` uses an `INNER JOIN active_periods AS next_period ON loan_id AND
next_period_date = period_date`. A loan that has no row in the active population for the next
period (because it was inactive, closed, or gapped) cannot satisfy the join and is excluded from
the denominator. This is the same pattern as the flagship's `inner join fct_payment on
next_months_on_book = subsequent_payment.months_on_book`.

`transition_events` uses the same self-join pattern to derive the `to_bucket` inline (the bucket
the loan occupies at the start of the _next_ period), eliminating the dependency on a separate
`fct_loan_state_event` table that the platform maintains.

## Alternatives considered

### Flat args vs. config dict

A single `config` dict argument (`roll_rate_matrix(config=dict(...))`) would have reduced
argument count in the caller. Rejected because: (a) each argument then loses independent
validation — the error message must say "key 'balance_col' missing from config dict" rather than
"'balance_col' is required"; (b) Jinja dicts have no enforced schema, so a misspelled key silently
defaults to `none` and produces a confusing SQL error instead of a compile-time message.

### Single-layer validation (only Jinja OR only SQL assertions)

Jinja-only validation catches argument problems at parse time but cannot catch data problems
(duplicate grain, null periods, negative balances) without a warehouse round-trip. SQL-only
assertion CTEs catch data problems but fire at query time — a missing required argument produces
a confusing SQL compilation error ("None is not subscriptable") rather than a helpful message.
Three layers are not over-engineering; each layer catches a class of errors the others cannot.

### Correlated-subquery approach for next-period lookup

Design 3 (rejected before implementation) used a correlated subquery of the form
`SELECT MIN(period_col) FROM relation WHERE period_col > current_period AND loan_id = current.loan_id`
to find the next period. On BigQuery this is an O(n²) operation: for each row in the outer query,
the subquery performs a full scan of `relation` filtered to that `loan_id`. On DuckDB with a
small dataset the difference is unobservable, but the self-join on a pre-computed `next_period_date`
is a hash join on both engines and degrades as O(n log n) with dataset size. The self-join also
makes the gap-continuity logic explicit in the query plan rather than buried in a scalar subquery.

### Target-specific branching scope

`target.type` branching is confined to two helper macros (`_date_trunc_month`, `_add_months`).
This is the minimum needed: `DATE_TRUNC(col, MONTH)` (BigQuery) vs `date_trunc('month', col)`
(ANSI/DuckDB) are genuinely incompatible; `INTERVAL (n) MONTH` arithmetic differs similarly.
Everything else is ANSI SQL. Wider branching would couple the macro's correctness to the number
of targets supported rather than to the algorithm.

## Consequences

**Easier:**
- Callers get a single-macro interface with precise error messages before any SQL runs.
- The integration-test harness (seed → model → dbt test) is reproducible without a live database:
  `dbt build --profiles-dir .` in `integration_tests/` using DuckDB `:memory:`.
- Gap-exclusion behavior is tested explicitly: `assert_gap_exclusion.sql` directly asserts the
  denominator count for Jan 2024 / current = 3 (not 4), confirming loan_c's inactive Feb row
  is excluded from the `at_risk_denominator`. The row-for-row expected seed additionally pins
  all absolute balance and rate values, including those affected by gap exclusion.
- Adding a new supported target requires changes only in two helper macros.

**Harder:**
- The three-layer validation adds ~30 lines to the macro body. The benefit (precise error messages
  at the right layer) justifies the cost; each line corresponds to one testable invariant.
- The `contract_assertions` cross-join means every execution of `active_periods` carries those
  three count queries. On very large relations the assertion CTEs add a fixed overhead (three
  filter + count passes). Callers on datasets > 10M rows should consider disabling runtime
  assertions via a future `skip_runtime_assertions=false` flag (out of scope for v0.1).

**Committed to:**
- The output schema (12 fixed columns + optional segment columns at the front) is the public
  contract for callers. Additive columns can be introduced in minor versions; removing or
  renaming existing columns requires a major version bump.
- Surrogate keys and `_loaded_at` stay out of the macro. They belong in the caller's wrapping
  model — this keeps the macro pure and prevents the package from imposing a particular key
  strategy on callers.
