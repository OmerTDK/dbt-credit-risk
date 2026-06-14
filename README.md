# dbt-credit-risk

dbt package of credit-risk analytics macros: roll-rate matrices, vintage curves, CPR/SMM prepayment curves

> Status: Phase 1 complete (roll-rate macro). Vintage and CPR/SMM macros are Phase 2.

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
├── roll_rate_matrix.sql          # Main macro: delinquency state-transition matrix
└── utils/
    ├── _date_trunc_month.sql     # Adapter: DATE_TRUNC (BigQuery) vs date_trunc (ANSI/DuckDB)
    └── _add_months.sql           # Adapter: DATE_ADD INTERVAL (BigQuery) vs + interval (ANSI)

integration_tests/
├── dbt_project.yml               # Self-contained dbt project, DuckDB :memory: target
├── profiles.yml                  # DuckDB :memory: profile (no credentials)
├── seeds/
│   ├── loan_performance.csv      # 5 loans × 6 months = 30 rows; covers all transition scenarios
│   ├── expected_roll_rate_matrix.csv  # 17 hand-computed expected output rows
│   └── loan_performance_segmented.csv # Same loans with product_type column for segment tests
├── models/
│   ├── roll_rate_output.sql      # Macro caller (unsegmented)
│   └── roll_rate_output_segmented.sql # Macro caller with segment_cols=['product_type']
└── tests/
    ├── assert_roll_rate_matches_expected.sql  # Full-outer-join row-for-row assertion
    ├── assert_no_negative_self_transition.sql
    ├── assert_probabilities_sum_to_one.sql    # SUM(transition_loan_count) = MAX(at_risk_loan_count)
    ├── assert_no_null_from_bucket.sql
    └── assert_gap_exclusion.sql               # Loan C's inactive month excluded from denominator
```

The macro implements a 12-CTE chain that computes non-self transitions via a self-join on
`next_period_date`, derives self-transitions as the residual of the denominator, and unions both.
The only target-specific code is in the two helper macros — everything else is ANSI SQL portable
across DuckDB and BigQuery.

See [docs/adr/0001-roll-rate-macro-api-and-contract.md](docs/adr/0001-roll-rate-macro-api-and-contract.md)
for the design tradeoffs.

## Results

- **dbt build runtime** (DuckDB `:memory:`, 30-row seed): 0.14 seconds for 10 nodes
  (3 seeds, 2 models, 5 tests)
- **Test count**: 7 pytest tests + 5 dbt singular tests = 12 total
- **Expected output rows**: 17 hand-verified rows covering 5 observation periods × multiple buckets
- **Kill-verified mutant**: changing `INNER JOIN` → `LEFT JOIN` in `at_risk_denominator` breaks
  gap exclusion and is caught by `assert_roll_rate_matches_expected` (5 mismatches returned)
- **CI runtime** (`make ci`): ~15 seconds on a MacBook M-series

## Quickstart

```bash
git clone https://github.com/OmerTDK/dbt-credit-risk
cd dbt-credit-risk
uv sync
make ci                 # lint + 7 pytest tests (includes dbt build + 5 dbt tests)
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

**Input contract** — one row per `(loan_id, period_date)` per active loan period:

| Column | Type | Contract |
|--------|------|----------|
| `loan_id_col` | VARCHAR | Natural key; `(loan_id, period_date)` must be unique for active rows |
| `period_col` | DATE | First-of-month; the macro DATE_TRUNCs defensively but the caller should pre-truncate |
| `bucket_col` | VARCHAR | Delinquency state label (`current`, `dpd_30`, etc.) |
| `balance_col` | NUMERIC | Beginning-of-period balance; must be >= 0 for active rows |
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
