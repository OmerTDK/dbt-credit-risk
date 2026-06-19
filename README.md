# dbt-credit-risk

dbt package of credit-risk analytics macros: roll-rate matrices, vintage curves, CPR/SMM prepayment curves

[![CI](https://github.com/OmerTDK/dbt-credit-risk/actions/workflows/ci.yml/badge.svg)](https://github.com/OmerTDK/dbt-credit-risk/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![dbt version](https://img.shields.io/badge/dbt-%3E%3D1.8.0-orange)](dbt_project.yml)

## Why this exists

Most dbt warehouses that model loan books end up writing the same roll-rate, vintage, and
prepayment SQL by hand. The SQL is subtle — gap exclusion, self-transition residuals, consecutive-
period guards — and the bugs (including the loan that silently inflates a denominator because it
had an inactive month) are hard to catch without a structured test harness.

This package extracts those macros from a working credit-data platform, generalizes the column
and relation parameters, and ships them with an integration-test harness that asserts correctness
row-for-row against hand-verified expected outputs.

## Installation

Add to your project's `packages.yml`:

```yaml
packages:
  - git: "https://github.com/OmerTDK/dbt-credit-risk"
    revision: v0.1.0
```

Run `dbt deps` to install. The package has no dependencies of its own and requires dbt >= 1.8.0.

> dbt Package Hub listing is pending repo going public. Once listed, the install will be:
> ```yaml
> packages:
>   - package: omertdk/credit_risk
>     version: [">=0.1.0", "<0.2.0"]
> ```

## Architecture

```
macros/
├── roll_rate_matrix.sql          # Delinquency state-transition matrix
├── vintage_curve.sql             # Cumulative default/prepayment by cohort × months-on-book
├── cpr_smm.sql                   # Single monthly mortality (SMM) + annualized CPR per cohort
├── schema.yml                    # Macro argument and description documentation
├── utils/
│   ├── _date_trunc_month.sql     # Adapter: DATE_TRUNC (BigQuery) vs date_trunc (ANSI/DuckDB)
│   ├── _date_trunc_quarter.sql   # Adapter: DATE_TRUNC QUARTER (BigQuery) vs date_trunc 'quarter'
│   ├── _generate_series.sql      # Adapter: GENERATE_ARRAY (BigQuery) vs range() (DuckDB)
│   └── _add_months.sql           # Adapter: DATE_ADD INTERVAL (BigQuery) vs + interval (ANSI)
└── generic_tests/
    ├── credit_risk_no_negative_self_transition.sql  # Self-transition loan count must be >= 0
    ├── credit_risk_no_null_from_bucket.sql          # from_bucket must not be null
    └── credit_risk_probabilities_sum_to_one.sql     # Counts sum to at_risk denominator per period

integration_tests/
├── dbt_project.yml               # Self-contained dbt project, DuckDB :memory: target
├── profiles.yml                  # DuckDB :memory: profile (no credentials)
├── seeds/
│   ├── loan_performance.csv           # 5 loans × 6 months; covers all roll-rate scenarios
│   ├── expected_roll_rate_matrix.csv  # 17 hand-computed expected output rows
│   ├── loan_performance_segmented.csv # Same loans with product_type for segment tests
│   ├── loan_performance_vintage.csv   # 17 loans, 3 cohorts; known defaults + prepayments by MOB
│   ├── expected_vintage_curve.csv     # 9 hand-computed vintage curve rows
│   ├── loan_performance_cpr.csv       # 6 loans, 2 cohorts; prepayment events at known MOBs
│   └── expected_cpr_smm.csv          # 5 hand-computed CPR/SMM rows (incl. non-zero CPR values)
├── models/
│   ├── roll_rate_output.sql           # roll_rate_matrix caller (unsegmented)
│   ├── roll_rate_output_segmented.sql # roll_rate_matrix caller with segment_cols=['product_type']
│   ├── vintage_curve_output.sql       # vintage_curve caller (quarter cohort granularity)
│   └── cpr_smm_output.sql            # cpr_smm caller (quarter cohort granularity)
└── tests/
    ├── assert_roll_rate_matches_expected.sql     # Full-outer-join row-for-row assertion
    ├── assert_no_negative_self_transition.sql
    ├── assert_probabilities_sum_to_one.sql       # SUM(transitions) = at_risk denominator
    ├── assert_no_null_from_bucket.sql
    ├── assert_gap_exclusion.sql                  # Inactive-month exclusion from denominator
    ├── assert_vintage_curve_matches_expected.sql # Full-outer-join row-for-row assertion
    ├── assert_vintage_curve_at_risk_identity.sql # loans_at_risk = cohort - defaults - prepays
    ├── assert_cpr_smm_matches_expected.sql       # Full-outer-join row-for-row assertion
    └── assert_cpr_smm_annualization.sql          # CPR = 1-(1-SMM)^12 verified independently
```

Three macro families sharing adapter helpers (`_date_trunc_month`, `_date_trunc_quarter`,
`_generate_series`) for BigQuery/DuckDB portability. All other SQL is ANSI-portable.

## Results

- **dbt build runtime** (DuckDB `:memory:`, 7 seeds): ~0.24 seconds for 26 nodes
  (7 seeds, 4 models, 15 data tests)
- **Test count**: 15 pytest tests + 15 dbt data tests = 30 total
- **Expected output rows**: 17 roll-rate + 9 vintage-curve + 5 CPR/SMM = 31 hand-verified rows
- **Supported adapters**: DuckDB (CI-tested on every PR), BigQuery (adapter helpers written
  and tested; portability confirmed by the adapter-isolation pattern in `macros/utils/`)
- **Kill-verified mutants**:
  - `INNER JOIN` → `LEFT JOIN` in `at_risk_denominator`: caught by `assert_gap_exclusion` (2 rows)
    and `assert_roll_rate_matches_expected` (5 rows)
  - `beginning_balance * 2` in `active_periods`: caught by `assert_roll_rate_matches_expected`
    (17 rows — all absolute balance columns wrong)
  - `MIN(beginning_balance)` vs first-period join in `vintage_curve`: caught by
    `assert_vintage_curve_matches_expected` (cohort_principal wrong for amortizing loans)
  - MOB-propagation filter bug (`total_mob` cutoff): caught by `assert_vintage_curve_matches_expected`
    (cumulative default count drops to 0 post-default event without fix)
  - Wrong CPR formula: caught by `assert_cpr_smm_annualization` (CPR != 1-(1-SMM)^12)
- **CI runtime** (`make ci`): ~25 seconds on a MacBook M-series (includes SQLFluff lint)

## Quickstart

### Try it locally (clone the repo)

```bash
git clone https://github.com/OmerTDK/dbt-credit-risk
cd dbt-credit-risk
uv sync
make ci                 # lint (ruff + SQLFluff) + 15 pytest tests (includes dbt build + 15 dbt data tests)
```

### Roll-rate matrix

Create a model in your project (e.g. `models/risk/fct_roll_rate.sql`):

```sql
{{ config(materialized='table') }}

select
    observation_period,
    period_length_months,
    from_bucket,
    to_bucket,
    transition_loan_count,
    at_risk_loan_count,
    transition_balance,   -- also available: at_risk_balance
    transition_rate,
    transition_balance_rate,
    is_low_count_cell,
    current_timestamp as _loaded_at
from (
    {{ credit_risk.roll_rate_matrix(
        relation=ref('stg_lending__monthly_performance'),
        loan_id_col='account_id',
        period_col='report_date',
        bucket_col='delinquency_category',
        balance_col='outstanding_principal',
        status_col='loan_status',
        active_status_value='active',
        period_length_months=1,
        minimum_cell_count=10
    ) }}
)
```

**Input relation** — one row per `(account_id, report_date)` per active loan period:

| Your column | Type | Contract |
|-------------|------|----------|
| `account_id` | VARCHAR | Natural key; `(account_id, report_date)` must be unique for active rows |
| `report_date` | DATE | First-of-month expected; the macro DATE_TRUNCs defensively |
| `delinquency_category` | VARCHAR | Delinquency state label (`current`, `dpd_30`, `dpd_60`, etc.) |
| `outstanding_principal` | NUMERIC | Beginning-of-period balance; must be >= 0 and non-null for active rows |
| `loan_status` | VARCHAR | Active/inactive flag; rows where `loan_status != 'active'` are excluded |

**Output schema** (fixed columns, optional segment columns prepended):

| Column | Type | Description |
|--------|------|-------------|
| `observation_period` | DATE | The from-period (start of month) |
| `period_length_months` | INTEGER | Months between periods (the `period_length_months` argument) |
| `from_bucket` | VARCHAR | Delinquency state at the start of the period |
| `to_bucket` | VARCHAR | Delinquency state at the start of the next period |
| `transition_loan_count` | INTEGER | Loans that moved from `from_bucket` to `to_bucket` |
| `at_risk_loan_count` | INTEGER | Loans in `from_bucket` that had a valid next-period row |
| `transition_balance` | DECIMAL(18,2) | Sum of beginning balances for transitioning loans |
| `at_risk_balance` | DECIMAL(18,2) | Sum of beginning balances for at-risk loans |
| `transition_rate` | DECIMAL(10,6) | `transition_loan_count / at_risk_loan_count` |
| `transition_balance_rate` | DECIMAL(10,6) | `transition_balance / at_risk_balance` |
| `is_low_count_cell` | BOOLEAN | True when `at_risk_loan_count < minimum_cell_count` |

Full contract, output schema, worked example, and edge cases: [`docs/macros/roll_rate_matrix.md`](docs/macros/roll_rate_matrix.md).

### Vintage curve

```sql
{{ config(materialized='table') }}

select
    origination_cohort,
    months_on_book,
    cohort_loan_count,
    cumulative_default_rate,
    cumulative_prepayment_rate,
    is_censored,
    current_timestamp as _loaded_at
from (
    {{ credit_risk.vintage_curve(
        relation=ref('stg_lending__monthly_performance'),
        loan_id_col='loan_id',
        origination_date_col='origination_date',
        performance_date_col='report_date',
        is_default_col='is_default',
        is_prepayment_col='is_prepayment',
        balance_col='beginning_balance',
        cohort_granularity='quarter',
        censored_threshold=10
    ) }}
)
```

**Input relation** — one row per `(loan_id, report_date)`:

| Your column | Type | Contract |
|-------------|------|----------|
| `loan_id` | VARCHAR | Natural key; `(loan_id, report_date)` must be unique |
| `origination_date` | DATE | Loan origination date; must not be null |
| `report_date` | DATE | Performance period date; must not be null |
| `is_default` | BOOLEAN | True on the first period the loan is in default |
| `is_prepayment` | BOOLEAN | True on the period of a full prepayment; suppressed if the loan has already defaulted |
| `beginning_balance` | NUMERIC | Beginning-of-period balance; the first period's value is used as origination balance |

**Output schema**:

| Column | Type | Description |
|--------|------|-------------|
| `origination_cohort` | DATE | Cohort start date (month or quarter truncated) |
| `months_on_book` | INTEGER | Months since origination (1-indexed) |
| `cohort_loan_count` | INTEGER | Total loans in this origination cohort |
| `cohort_principal` | DECIMAL(18,2) | Sum of origination balances across the cohort |
| `cumulative_default_count` | INTEGER | Loans defaulted by this MOB |
| `cumulative_prepayment_count` | INTEGER | Loans prepaid (non-defaulted) by this MOB |
| `surviving_non_defaulted_count` | INTEGER | `cohort_loan_count - cumulative_default_count` |
| `loans_at_risk_count` | INTEGER | `cohort_loan_count - cumulative_default_count - cumulative_prepayment_count` |
| `cumulative_default_rate` | DECIMAL(10,6) | `cumulative_default_count / cohort_loan_count` |
| `cumulative_prepayment_rate` | DECIMAL(10,6) | `cumulative_prepayment_count / surviving_non_defaulted_count` |
| `is_censored` | BOOLEAN | True when `loans_at_risk_count < censored_threshold` |

Full contract, output schema, worked example, and edge cases: [`docs/macros/vintage_curve.md`](docs/macros/vintage_curve.md).

### CPR/SMM

```sql
{{ config(materialized='table') }}

select
    origination_cohort,
    months_on_book,
    performing_pool_balance,
    smm_rate,
    cpr_rate,
    current_timestamp as _loaded_at
from (
    {{ credit_risk.cpr_smm(
        relation=ref('stg_lending__monthly_performance'),
        loan_id_col='loan_id',
        origination_date_col='origination_date',
        performance_date_col='report_date',
        beginning_balance_col='beginning_balance',
        prepaid_amount_col='prepaid_amount',
        is_active_col='is_active',
        is_prepayment_col='is_prepayment',
        cohort_granularity='quarter'
    ) }}
)
```

**Input relation** — one row per `(loan_id, report_date)`:

| Your column | Type | Contract |
|-------------|------|----------|
| `loan_id` | VARCHAR | Natural key; `(loan_id, report_date)` must be unique |
| `origination_date` | DATE | Loan origination date; must not be null |
| `report_date` | DATE | Performance period date; must not be null |
| `beginning_balance` | NUMERIC | Beginning-of-period balance; must be >= 0 |
| `prepaid_amount` | NUMERIC | Unscheduled principal repaid this period (excess over scheduled payment); 0 for non-prepaying rows |
| `is_active` | BOOLEAN | True for loans still in the performing or prepaying pool; false for closed/written-off |
| `is_prepayment` | BOOLEAN | True on the period of a prepayment event; that period's `prepaid_amount` goes to the numerator |

**Output schema**:

| Column | Type | Description |
|--------|------|-------------|
| `origination_cohort` | DATE | Cohort start date (month or quarter truncated) |
| `months_on_book` | INTEGER | Months since origination (1-indexed) |
| `performing_pool_balance` | DECIMAL(18,2) | Sum of `beginning_balance` for active non-prepaying loans (SMM denominator) |
| `prepaid_balance` | DECIMAL(18,2) | Sum of `prepaid_amount` for active prepaying loans (SMM numerator) |
| `eligible_loan_count` | INTEGER | Active non-prepaying loan count (denominator pool size) |
| `prepaying_loan_count` | INTEGER | Active prepaying loan count (numerator pool size) |
| `smm_rate` | DECIMAL(10,6) | `prepaid_balance / performing_pool_balance` (conditional pool) |
| `cpr_rate` | DECIMAL(10,6) | `1 - (1 - smm_rate)^12`; NULL when `performing_pool_balance = 0` |

> SMM uses the **conditional-pool** denominator: `SMM = prepaid / performing_non_prepaying`. This
> is the European consumer-lending convention. US agency (ABS) convention uses total-pool. See
> [`docs/macros/cpr_smm.md`](docs/macros/cpr_smm.md) for details.

Full contract, output schema, worked example, and edge cases: [`docs/macros/cpr_smm.md`](docs/macros/cpr_smm.md).

## Hardest design decision

The single hardest design decision in this package is the **gap-continuity guard** in
`roll_rate_matrix`: using `INNER JOIN` (not `LEFT JOIN`) in the `at_risk_denominator` CTE.

A loan that has no row in the active population for the next observation period (paid off,
written off, missing data) cannot "transition" anywhere — it left the at-risk pool before the
next period began. Including it in the denominator with a `LEFT JOIN` overstates the at-risk
count and deflates all transition rates for that period/bucket pair.

The bug is completely invisible in a naively-constructed test. With a `LEFT JOIN`, the output
still has one row per (period, from_bucket, to_bucket) with plausible-looking counts — just
wrong. Only a test with a specific inactive loan that is expected to be *excluded* from the
denominator catches it. That test is `assert_gap_exclusion.sql`: it asserts that
`loan_c` (inactive in February) is absent from the January at-risk denominator, producing
`at_risk_loan_count = 3` not 4. The row-for-row assertion on the full expected seed pins all
downstream balance and rate columns as well.

The same INNER JOIN pattern appears in `transition_events` — a loan with no next-period row
produces no transition observation, which is correct: we can't know what bucket it "became"
if it disappeared.

This decision, its test, and the full tradeoff analysis are in [`docs/adr/0001-roll-rate-macro-api-and-contract.md`](docs/adr/0001-roll-rate-macro-api-and-contract.md).

## Macro docs

- [`docs/macros/roll_rate_matrix.md`](docs/macros/roll_rate_matrix.md)
- [`docs/macros/vintage_curve.md`](docs/macros/vintage_curve.md)
- [`docs/macros/cpr_smm.md`](docs/macros/cpr_smm.md)

## Design decisions

See [docs/adr/](docs/adr/) — each major decision documented with its trade-offs.

| ADR | Decision |
|-----|----------|
| [ADR-0001](docs/adr/0001-roll-rate-macro-api-and-contract.md) | Roll-rate macro API, three-layer validation, gap-continuity guard |
| [ADR-0002](docs/adr/0002-vintage-curve-and-cpr-smm-macro-design.md) | Origination balance, MOB propagation, conditional-pool SMM |
| [ADR-0003](docs/adr/0003-documentation-and-input-contract-approach.md) | Prose contracts vs. dbt enforced contracts, doc-block placement |
| [ADR-0004](docs/adr/0004-hub-publish-and-release-strategy.md) | Semver v0.1.0, Hub publication flow, `require-dbt-version` floor |

## Standards

Engineering conventions in [standards/](standards/) govern all code in this repo.

## License

Apache-2.0. See [LICENSE](LICENSE).
