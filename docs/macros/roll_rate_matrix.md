# `roll_rate_matrix`

Computes a delinquency state-transition (roll-rate) matrix from a caller-supplied
loan-performance relation. Returns one row per `(observation_period, from_bucket, to_bucket)`
combination, with transition counts, balances, and rates.

## Signature

```jinja
{% macro roll_rate_matrix(
    relation,
    loan_id_col,
    period_col,
    bucket_col,
    balance_col,
    status_col,
    active_status_value,
    segment_cols=[],
    period_length_months=1,
    minimum_cell_count=10
) %}
```

## Arguments

| Argument | Required | Type | Description |
|----------|----------|------|-------------|
| `relation` | yes | dbt Relation | The caller's `ref()` or `source()`. One row per `(loan_id, period_date)` per active period. |
| `loan_id_col` | yes | string | Physical column name for the loan natural key. |
| `period_col` | yes | string | Physical column name for the performance period DATE. Must be first-of-month (macro DATE_TRUNCs defensively, but pre-truncation is expected). |
| `bucket_col` | yes | string | Physical column name for the delinquency state label. |
| `balance_col` | yes | string | Physical column name for the beginning-of-period balance (NUMERIC >= 0 for active rows). |
| `status_col` | yes | string | Physical column name for the active/inactive status. |
| `active_status_value` | yes | string | The value in `status_col` that marks a loan as at-risk. |
| `segment_cols` | no | list | Extra grouping dimensions (e.g. `['product_type', 'risk_tier']`). Empty list produces an unsegmented matrix. |
| `period_length_months` | no | integer | Number of months per period. Default 1. |
| `minimum_cell_count` | no | integer | Threshold below which `is_low_count_cell` is `true`. Default 10. |

## Input contract

- `(loan_id_col, period_col)` must be unique for rows where `status_col = active_status_value`.
  A duplicate pair causes a runtime division-by-zero in `contract_assertions`.
- `period_col` must not be null for active rows.
- `balance_col` must be >= 0 for active rows.

All three constraints are enforced at query time via the `contract_assertions` CTE. Arguments
are validated at compile time (before any SQL is generated) by Jinja guards in the macro body.

## Output schema

Segment columns appear first, in caller-supplied order. No surrogate key or `_loaded_at` —
those belong in the caller's wrapping model.

| Column | Type | Description |
|--------|------|-------------|
| `[segment_cols...]` | VARCHAR | Zero or more, at front |
| `observation_period` | DATE | Start of the observation window |
| `period_length_months` | INTEGER | The argument value, carried through |
| `from_bucket` | VARCHAR | Delinquency state at `observation_period` |
| `to_bucket` | VARCHAR | Delinquency state at the next period |
| `transition_loan_count` | INTEGER | Loans moving from → to |
| `at_risk_loan_count` | INTEGER | Active loans in `from_bucket` with a confirmed successor period |
| `transition_balance` | DECIMAL(18,2) | Sum of beginning balances for transitioning loans |
| `at_risk_balance` | DECIMAL(18,2) | Sum of beginning balances for all at-risk loans |
| `transition_rate` | DECIMAL(10,6) | `transition_loan_count / at_risk_loan_count` |
| `transition_balance_rate` | DECIMAL(10,6) | `transition_balance / at_risk_balance` |
| `is_low_count_cell` | BOOLEAN | `at_risk_loan_count < minimum_cell_count` |

**Key invariant:** `SUM(transition_loan_count) = MAX(at_risk_loan_count)` for every
`(observation_period, from_bucket, [segment_cols])` group. Self-transitions are the residual
after all non-self transitions have been subtracted.

## Gap-continuity guard

A loan that is absent from the active population in the next period (paid off, inactive, or
gapped data) cannot satisfy the self-join in `at_risk_denominator` and is excluded from the
denominator. This prevents a loan that paid off in month N from inflating the denominator of
month N-1.

## Worked example

Input (30 rows, 5 loans × 6 months, DuckDB):

```
loan_a: current all 6 months
loan_b: current m1-m2, dpd_30 m3, dpd_60 m4, current m5-m6
loan_c: current m1, inactive m2, dpd_30 m3-m6   (gap exclusion loan)
loan_d: current m1, dpd_30 m2-m3, dpd_60 m4, written_off m5-m6
loan_e: dpd_30 all 6 months
```

Output (17 rows, 5 observation periods, no segment):

```
2024-01-01 | current    | current    | 2 | 3 | 0.666667
2024-01-01 | current    | dpd_30     | 1 | 3 | 0.333333
2024-01-01 | dpd_30     | dpd_30     | 1 | 1 | 1.000000
...
```

Loan C's month-1 row is NOT in the Jan denominator (at_risk_loan_count=3, not 4) because
its month-2 row has `loan_status='inactive'` and does not appear in `active_periods`. The
inner join on `next_period_date` excludes it.

## Caller example

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
