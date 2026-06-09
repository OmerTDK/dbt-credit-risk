# Brief 02 — Open-Source dbt Credit-Risk Package

Working title: `dbt-credit-risk` (final name decided in this project's own brainstorm).

## Mission

Publish an open-source dbt package of reusable credit-risk macros — roll-rate matrices,
vintage curves, and CPR/SMM prepayment curves — extracted and generalized from the credit
data platform's risk marts. Any analytics engineer with a loan-performance table should be
able to install the package from the dbt Package Hub, point the macros at their own
columns, and get correct, tested risk analytics without writing the SQL themselves.

## Staff signal

**Axis E — Platform, governance & enablement.** This is the highest signal-per-effort
project in the whole portfolio: a *published, installed-by-strangers* package signals that
other engineers trust your code, which is exactly the "self-serve enablement — work that
multiplies a team" axis of the staff thesis. It also proves extraction judgment: taking
project-specific risk marts and refactoring them into a generic, configurable,
integration-tested public API is a different (and rarer) skill than writing the marts in
the first place.

## Scope

**In:**

- Three macro families, extracted from the platform's risk marts:
  - **Roll-rate matrices** — delinquency state-transition probabilities between periods.
  - **Vintage curves** — cumulative default/prepayment by origination cohort × months-on-book.
  - **CPR/SMM** — prepayment speed curves (single monthly mortality and its annualized form).
- A documented input contract per macro (required columns, types, grain) instead of
  hardcoded column names — callers map their own loan-performance schema.
- Bundled sample data (seeds) shaped like a generic loan-performance table, with known
  expected outputs.
- An integration-test project inside the repo that runs every macro against the bundled
  sample data and asserts results against the expected outputs.
- Per-macro documentation: purpose, arguments, input contract, worked example, rendered SQL.
- Publication to the dbt Package Hub with semver releases and a changelog.

**Out:**

- Any risk methodology beyond the three macro families (no ECL, no stress testing, no
  scoring — those live in the platform or other projects).
- Dashboards, BI, or semantic-layer definitions.
- Anything specific to the platform's synthetic bank — the package must stand alone with
  zero knowledge of where it was extracted from.
- Multi-warehouse adapters beyond the tested targets (DuckDB and BigQuery); other adapters
  are welcome as community contributions, not launch scope.

## Architecture

- **Macro layer** — pure SQL/Jinja macros, one file per macro, parameterized over the
  caller's relation and column names. No models in the package itself; consumers
  materialize results in their own projects.
- **Input contract** — each macro documents and validates its expected input grain (e.g.
  one row per loan per performance month) and required columns, failing loudly when the
  contract is not met rather than producing silently wrong risk numbers.
- **Integration-test harness** — a small dbt project in the repo (`integration_tests/`)
  with seed files of sample loan-performance data plus seeds of hand-verified expected
  outputs; tests assert macro output equals expected output row-for-row.
- **CI** — lint (SQLFluff) plus the full integration-test run against DuckDB on every PR;
  a BigQuery job validates portability before each release.
- **Release flow** — semver tags, changelog, dbt Package Hub registration; README
  documents installation via `packages.yml` and a quickstart per macro.

## Build phases

- **Phase 0** — repo scaffold from the template: CI, lint configs, standards, ADR skeleton.
- **Phase 1** — extract the roll-rate macro from the platform's risk marts, generalize its
  column/relation parameters, and stand up the integration-test harness around it
  (sample seeds + expected outputs). One macro fully proven end-to-end before the rest.
- **Phase 2** — vintage-curve and CPR/SMM macros through the same harness.
- **Phase 3** — per-macro documentation, input contracts, README quickstart, generated docs.
- **Phase 4** — BigQuery portability validation, semver v0.1.0 release, dbt Package Hub
  publication.
- Each phase ends with: an ADR, tests, and a README update.

## Stack

- **dbt-core** — SQL/Jinja macros, seeds, generic tests.
- **DuckDB** — local development and CI integration tests.
- **BigQuery** — second supported target; portability validated pre-release.
- **SQLFluff + GitHub Actions** — lint and integration tests on every PR.
- **dbt Package Hub** — distribution channel.

## Deployed means

Installable by strangers from the dbt Package Hub: a published semver release that any dbt
project can pull in via `packages.yml` and run against its own loan-performance data, with
generated docs and a changelog public alongside it.

## Dependencies

- **Credit data platform, Phase 3 (risk marts) must exist first.** The macros are
  extracted from the platform's working roll-rate, vintage, and CPR/SMM marts — extraction
  from proven code, not greenfield invention, is the point.
- Sequenced directly after the platform in the program build order, before the fraud
  feature store and LLM analyst.

## Definition of done

- [ ] README that tells the **system story**, with an architecture diagram.
- [ ] **ADRs** for each major design decision (the tradeoff, not just the choice).
- [ ] **Full CI green** — lint + tests on every PR.
- [ ] Meaningful **tests / data contracts** (not just `not_null`/`unique`).
- [ ] **Observability** where applicable (test results, freshness, anomalies).
- [ ] A **results section** with quantified outcomes (runtime, cost, test count, savings).
- [ ] **Generated docs** published.
- [ ] A short writeup of the **single hardest design decision**.
- [ ] Conforms to **Omer's coding standards** (§6).
- [ ] **Public** repo with a clean history once polished.
