# dbt-credit-risk

dbt package of credit-risk analytics macros: roll-rate matrices, vintage curves, CPR/SMM prepayment curves

> Status: Phase 2 complete — roll-rate matrix, vintage curve, and CPR/SMM macros all implemented with integration tests.

## Why this exists

Most dbt warehouses that model loan books end up writing the same roll-rate, vintage, and
prepayment SQL by hand. The SQL is subtle — gap exclusion, self-transition residuals, consecutive-
period guards — and the bugs (including the loan that silently inflates a denominator because it
had an inactive month) are hard to catch without a structured test harness.

This package extracts those macros from a working credit-data platform, generalizes the column
and relation parameters, and ships them with an integration-test harness that asserts correctness
row-for-row against hand-verified expected outputs.

## Architecture

```
macros/
├── roll_rate_matrix.sql          # Delinquency state-transition matrix
├── vintage_curve.sql             # Cumulative default/prepayment by cohort × months-on-book
├── cpr_smm.sql                   # Single monthly mortality (SMM) + annualized CPR per cohort
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
│   ├── loan_performance_vintage.csv   # 6 loans, 2 cohorts; known defaults + prepayments by MOB
│   ├── expected_vintage_curve.csv     # 9 hand-computed vintage curve rows
│   ├── loan_performance_cpr.csv       # 5 loans, 2 cohorts; prepayment events at known MOBs
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

Three macro families sharing the same adapter helpers (`_date_trunc_month`, `_date_trunc_quarter`,
`_generate_series`) for BigQuery/DuckDB portability. All other SQL is ANSI-portable across DuckDB
and BigQuery.

See [docs/adr/](docs/adr/) for design tradeoffs per phase.

## Results

- **dbt build runtime** (DuckDB `:memory:`, 7 seeds): ~0.24 seconds for 26 nodes
  (7 seeds, 4 models, 15 data tests)
- **Test count**: 15 pytest tests + 15 dbt data tests = 30 total
- **Expected output rows**: 17 roll-rate + 9 vintage-curve + 5 CPR/SMM = 31 hand-verified rows
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

```bash
git clone https://github.com/OmerTDK/dbt-credit-risk
cd dbt-credit-risk
uv sync
make ci                 # lint (ruff + SQLFluff) + 15 pytest tests (includes dbt build + 15 dbt data tests)
```

### Using the macro in your project

Add to your `packages.yml`:

```yaml
packages:
  - git: "https://github.com/OmerTDK/dbt-credit-risk"
    revision: main
```

Then in a model:

```sql
{{ config(materialized='table') }}

select
    {{ dbt_utils.generate_surrogate_key([
        'cast(observation_period as varchar)',
        'from_bucket',
        'to_bucket'
    ]) }} as roll_rate_key,
    roll_rates.*,
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
        segment_cols=['product_type', 'risk_tier'],
        period_length_months=1,
        minimum_cell_count=10
    ) }}
) as roll_rates
```

> The example above uses `dbt_utils.generate_surrogate_key` — add `dbt-labs/dbt_utils` to your
> own `packages.yml` if you need surrogate keys. The `credit_risk` package itself has no
> dependencies.

**Input contract** — one row per `(loan_id, period_date)` per active loan period:

| Column | Type | Contract |
|--------|------|----------|
| `loan_id_col` | VARCHAR | Natural key; `(loan_id, period_date)` must be unique for active rows |
| `period_col` | DATE | First-of-month; the macro DATE_TRUNCs defensively but the caller should pre-truncate |
| `bucket_col` | VARCHAR | Delinquency state label (`current`, `dpd_30`, etc.) |
| `balance_col` | NUMERIC | Beginning-of-period balance; must be >= 0 and non-null for active rows |
| `status_col` | VARCHAR | Active/inactive flag; rows where this != `active_status_value` are excluded |

**Output schema** — the macro returns this SELECT (no surrogate key, no `_loaded_at`):

| Column | Type |
|--------|------|
| `[segment_cols...]` | VARCHAR |
| `observation_period` | DATE |
| `period_length_months` | INTEGER |
| `from_bucket` | VARCHAR |
| `to_bucket` | VARCHAR |
| `transition_loan_count` | INTEGER |
| `at_risk_loan_count` | INTEGER |
| `transition_balance` | DECIMAL(18,2) |
| `at_risk_balance` | DECIMAL(18,2) |
| `transition_rate` | DECIMAL(10,6) |
| `transition_balance_rate` | DECIMAL(10,6) |
| `is_low_count_cell` | BOOLEAN |

## Design decisions

See [docs/adr/](docs/adr/) — each major decision documented with its trade-offs.

## Standards

Engineering conventions in [standards/](standards/) govern all code in this repo.
