# ADR-0003: Documentation and Input-Contract Approach

**Date:** 2026-06-14
**Status:** Accepted

## Context

Phase 3 adds per-macro documentation and formalizes the input contracts for all three macros.
Two concrete choices required non-obvious tradeoffs:

1. **Where to express the input contract** — prose in documentation files vs. dbt contract
   enforcement (`contract: enforced: true` in YAML schema files) vs. runtime SQL assertions
   already in the macro body.
2. **Where to wire doc-block descriptions** — in the integration-test project's `_models.yml`,
   in the package's own schema YAML, or as a deferred deliverable pending dbt Hub publication.

## Decision

### 1. Prose contract in `docs/macros/` + runtime SQL assertions in the macro body

The input contract is expressed as explicit prose in `docs/macros/<macro>.md`, cross-referenced
against the seeds and integration-test models that demonstrate it. The macro bodies already
enforce the most critical invariants (unique grain, non-null dates, non-negative balances)
at query time via division-by-zero assertion CTEs.

dbt's `contract: enforced: true` mechanism was evaluated and rejected for this package
(see Alternatives considered).

### 2. Doc-block descriptions wired into `integration_tests/_models.yml` for output columns

Output column descriptions are added directly to `integration_tests/models/_models.yml`
under each model's `columns:` block. This is the correct place in the integration-test
project structure: the YAML describes the models in `integration_tests/models/`, and the
descriptions render in `dbt docs` when the integration-test project's docs are generated.

Generating the docs site requires `dbt docs generate` inside `integration_tests/`, which
requires a running DuckDB target. This is supported by the `make dbt-build` target but not
by the `make ci` target (which runs pytest, which invokes `dbt build` via subprocess). The
published docs site is deferred to Phase 4 alongside Hub publication. See the Deferred
section below.

## Alternatives considered

### A. dbt enforced contracts (`contract: enforced: true`)

dbt enforced contracts (`contract: enforced: true` in a model's YAML) require the model to
declare every output column with an explicit data type, and dbt validates the compiled SQL's
output schema matches the declaration before running. This is a schema-enforcement mechanism
for *output columns*, not for *input columns*.

For enforcing input column presence and type, dbt offers source `columns:` declarations plus
`not_null` and `accepted_values` tests, but these are post-materialization tests — they fail
after the model runs, not before.

The macros enforce their input contract at query-time via SQL assertion CTEs (division-by-zero
on grain violations, null dates, negative balances). This catches violations at runtime with a
clear error and has no dependency on the caller's schema YAML being correctly configured.
Adding a separate dbt-enforced output contract on top would require callers to add a schema
YAML block for every model that wraps a macro call — significant boilerplate for minimal added
safety. Rejected: the existing three-layer validation (Jinja compile-time + SQL runtime +
integration-test assertions) covers the same invariants with less caller burden.

### B. Separate `docs/` schema YAML in the package root (not in `integration_tests/`)

dbt packages can ship a `models/` directory (none here — this package is macros-only) and
associated `schema.yml` files. For macro documentation, dbt supports doc-block strings in
`macros/` YAML files (e.g. `macros/schema.yml`) that render in `dbt docs`. Adding a
`macros/schema.yml` with `macros:` entries and argument descriptions was considered.

Rejected because: (a) the `macros/schema.yml` doc-blocks do not render argument descriptions
in dbt Core's generated docs site as of dbt 1.8 — only the macro name and description appear,
not the argument table; (b) the prose documentation in `docs/macros/` is richer than what
the YAML format supports (worked examples, edge cases, input contract tables). The YAML format
is not a replacement for the markdown documentation. Wiring doc-blocks for the macro output
columns in the integration-test project's `_models.yml` gives the most value for the
generated-docs use case.

### C. Publish the generated docs site in Phase 3

Publishing requires `dbt docs generate` + hosting (GitHub Pages or similar). `dbt docs
generate` against the integration-test project produces `target/catalog.json` and
`target/manifest.json`. Hosting requires either committing these to the repo (large, unstable
binary blobs) or a CI deployment step. Both belong in Phase 4 alongside Hub publication,
semver tagging, and the BigQuery portability validation. Deferred.

## Consequences

**Easier:**
- Callers get precise input contract documentation at the prose level — column names, types,
  grain, null rules, ordering assumptions, and denominator conventions — without needing to
  configure a dbt schema YAML for each macro call.
- The integration-test seeds (`loan_performance.csv`, `loan_performance_vintage.csv`,
  `loan_performance_cpr.csv`) serve as living examples of compliant input relations: any
  caller can examine a seed to see exactly what the macro expects.
- The runtime SQL assertions in the macro bodies fail loudly at query time when invariants are
  violated, without requiring any caller-side configuration.

**Harder:**
- The prose contract and the SQL assertions are maintained separately. If a future version
  adds a new assertion (e.g. non-negative prepaid amounts), both the SQL and the relevant
  `docs/macros/` file must be updated in the same PR. A linting rule or CI check to enforce
  this sync does not exist yet; it relies on PR review discipline.
- The generated docs site (rendered output column descriptions, macro argument table in dbt
  docs) is not available until Phase 4. Callers who want rendered docs must run
  `dbt docs generate` locally in `integration_tests/` using `make dbt-build` + `make dbt-parse`.

**Committed to:**
- `docs/macros/<macro>.md` is the authoritative input contract for each macro. Any change to a
  macro's argument signature, SQL assertion logic, or output schema requires a corresponding
  update to the relevant doc file in the same PR.
- Output column descriptions in `integration_tests/models/_models.yml` are the source of truth
  for `dbt docs` rendering. Additive columns can be introduced in minor versions; removing or
  renaming existing output columns requires a major version bump and an update to both the
  `_models.yml` descriptions and the `docs/macros/` prose.

## Deferred to Phase 4

- **Published docs site.** `dbt docs generate` inside `integration_tests/` + deploy to
  GitHub Pages or docs.getdbt.com. The generated site requires a running DuckDB target and
  a CI deployment step.
- **`macros/schema.yml` argument descriptions.** If dbt adds first-class argument description
  rendering in a future version, a `macros/schema.yml` with argument doc-blocks can be added
  as an additive improvement.
