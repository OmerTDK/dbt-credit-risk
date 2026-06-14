# dbt-credit-risk

dbt package of credit-risk analytics macros: roll-rate matrices, vintage curves, CPR/SMM prepayment curves

> Status: Phase 3 complete — all three macros documented with input contracts, quickstart, and column-level descriptions wired into the integration-test project. Published docs site deferred to Phase 4 (Hub publication).

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

### Try it locally (clone the repo)

```bash
git clone https://github.com/OmerTDK/dbt-credit-risk
cd dbt-credit-risk
uv sync
make ci                 # lint (ruff + SQLFluff) + 15 pytest tests (includes dbt build + 15 dbt data tests)
```

### Install in your own dbt project

> Note: dbt Package Hub publication is Phase 4. Until then, install via git ref.

Add to your project's `packages.yml`:

```yaml
packages:
  - git: "https://github.com/OmerTDK/dbt-credit-risk"
    revision: main
```

Run `dbt deps` to install. The package has no dependencies of its own.

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

> SMM uses the **conditional-pool** denominator: `SMM = prepaid / performing_non_prepaying`. This
> is the European consumer-lending convention. US agency (ABS) convention uses total-pool. See
> [`docs/macros/cpr_smm.md`](docs/macros/cpr_smm.md) for details.

Full contract, output schema, worked example, and edge cases: [`docs/macros/cpr_smm.md`](docs/macros/cpr_smm.md).

### Macro docs

- [`docs/macros/roll_rate_matrix.md`](docs/macros/roll_rate_matrix.md)
- [`docs/macros/vintage_curve.md`](docs/macros/vintage_curve.md)
- [`docs/macros/cpr_smm.md`](docs/macros/cpr_smm.md)

## Design decisions

See [docs/adr/](docs/adr/) — each major decision documented with its trade-offs.

## Standards

Engineering conventions in [standards/](standards/) govern all code in this repo.
