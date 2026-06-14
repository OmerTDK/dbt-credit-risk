# `vintage_curve`

Computes a cumulative default and prepayment curve from a caller-supplied loan-performance
relation. Returns one row per `(origination_cohort, months_on_book)` combination, with cohort
sizes, cumulative event counts, and rates.

## Signature

```jinja
{% macro vintage_curve(
    relation,
    loan_id_col,
    origination_date_col,
    performance_date_col,
    is_default_col,
    is_prepayment_col,
    balance_col,
    cohort_granularity='quarter',
    censored_threshold=10
) %}
```

## Arguments

| Argument | Required | Type | Description |
|----------|----------|------|-------------|
| `relation` | yes | dbt Relation | The caller's `ref()` or `source()`. One row per `(loan_id, performance_date)`. |
| `loan_id_col` | yes | string | Physical column name for the loan natural key. |
| `origination_date_col` | yes | string | Physical column name for the loan origination DATE. Must not be null. Used to assign each loan to a cohort. |
| `performance_date_col` | yes | string | Physical column name for the performance period DATE. Must not be null. `(loan_id, performance_date)` must be unique across the input. |
| `is_default_col` | yes | string | Physical column name for the default event boolean. The first period where this is `true` is recorded as the loan's `default_mob`. |
| `is_prepayment_col` | yes | string | Physical column name for the prepayment event boolean. The first period where this is `true` AND the loan has not defaulted is recorded as the loan's `prepayment_mob`. |
| `balance_col` | yes | string | Physical column name for the beginning-of-period balance. The value at the loan's earliest observed performance date is used as its origination balance for `cohort_principal`. |
| `cohort_granularity` | no | string | `'month'` or `'quarter'`. Controls how `origination_date` is truncated into `origination_cohort`. Default `'quarter'`. |
| `censored_threshold` | no | integer | Threshold below which `is_censored` is `true`. When `loans_at_risk_count < censored_threshold`, the rates at that MOB are statistically unreliable. Default `10`. |

## Input contract

The relation must satisfy all of the following. Violations raise a runtime division-by-zero
error via the `contract_assertions` CTE (same pattern as `roll_rate_matrix`):

- `(loan_id_col, performance_date_col)` must be unique. Duplicate pairs cause grain violation.
- `origination_date_col` must not be null for any row.
- `performance_date_col` must not be null for any row.

Additional assumptions the macro depends on but does not assert at runtime:

- `is_default_col` and `is_prepayment_col` should be `BOOLEAN`-compatible. The macro casts
  both to `boolean` internally.
- `balance_col` should be numeric and non-negative. The macro casts it to `double` internally
  but does not assert non-negativity (unlike `roll_rate_matrix` and `cpr_smm`).
- A loan is expected to have at least one row. Loans with zero rows in the input are
  naturally absent from all output.
- A loan that defaults at MOB N is expected to have `is_default = true` at MOB N. Subsequent
  rows (if present) are used only for `total_mob` bookkeeping — not for re-attributing the
  default event. The macro picks `MIN(months_on_book) WHERE is_default` as the default MOB.
- A prepayment event is counted only if the loan has not already defaulted. If a loan has
  both `default_mob` and `prepayment_mob` in the data (i.e. both flags appear on separate
  rows), the prepayment is suppressed and the loan counts only toward cumulative defaults.
  This is enforced in the `loan_summary` CTE:
  ```sql
  case when loan_totals.default_mob is null then loan_totals.prepayment_mob_raw end
  ```

**Grain:** one row per `(loan_id, performance_date)`. All rows participate regardless of any
status column — there is no active/inactive filter in this macro. If you want to exclude
written-off loans, filter them out in the staging layer before calling this macro.

**Months-on-book calculation:** `(year_diff * 12) + month_diff + 1`. A loan originated
2024-01-01 with a performance row on 2024-01-01 is MOB 1; a row on 2024-02-01 is MOB 2.

## Output schema

| Column | Type | Description |
|--------|------|-------------|
| `origination_cohort` | DATE | First-of-month (monthly granularity) or first-of-quarter (quarterly granularity) date representing the cohort. |
| `months_on_book` | INTEGER | Months elapsed since origination, 1-indexed. |
| `cohort_loan_count` | INTEGER | Total loans in the cohort, fixed at every MOB. |
| `cohort_principal` | DECIMAL(18,2) | Sum of origination-period balances across all cohort loans. Fixed at every MOB. |
| `cumulative_default_count` | INTEGER | Loans that have defaulted by this MOB (inclusive). Monotonically non-decreasing. |
| `cumulative_prepayment_count` | INTEGER | Loans that have prepaid (and not defaulted) by this MOB. Monotonically non-decreasing. |
| `surviving_non_defaulted_count` | INTEGER | `cohort_loan_count - cumulative_default_count`. Does not subtract prepaid loans. |
| `loans_at_risk_count` | INTEGER | `cohort_loan_count - cumulative_default_count - cumulative_prepayment_count`. Loans still eligible to default or prepay. |
| `cumulative_default_rate` | DECIMAL(10,6) | `cumulative_default_count / cohort_loan_count`. |
| `cumulative_prepayment_rate` | DECIMAL(10,6) | `cumulative_prepayment_count / surviving_non_defaulted_count`. Prepayment rate is conditional on non-default survival. |
| `is_censored` | BOOLEAN | `loans_at_risk_count < censored_threshold`. Flag for statistically unreliable tail observations. |

**Key invariant:** `loans_at_risk_count = cohort_loan_count - cumulative_default_count - cumulative_prepayment_count`.
Verified by `assert_vintage_curve_at_risk_identity` in the integration-test suite.

**Monotonicity:** cumulative counts are computed as running flags across the `mob_spine` —
a loan that defaulted at MOB 2 contributes `has_defaulted_by_mob = 1` at every subsequent
MOB in its cohort, even if it has no rows past MOB 2.

## Event propagation

The macro builds a `mob_spine` (one row per cohort × MOB up to the cohort maximum) and joins
all cohort loans to every MOB. A loan that defaults at MOB 2 and ceases to appear in the
input after MOB 2 will still be counted as defaulted at MOBs 3, 4, 5, and so on. This is
intentional: once a loan has defaulted, it remains defaulted. The alternative — filtering
each loan only to its observed MOBs — would cause the cumulative default rate to fall back
toward zero after a defaulted loan's last data row, which is the wrong shape for a vintage
curve.

## Worked example

Input (`loan_performance_vintage` seed, 30 rows, 10 loans, 3 cohorts):

```
Q1-2024 cohort (4 loans, origination 2024-01-01):
  loan_a: 6 months, no events
  loan_b: 2 months, defaults at MOB 2
  loan_c: 3 months, prepays at MOB 3 (no prior default)
  loan_g: 3 months, defaults at MOB 2, prepayment flag appears at MOB 3 (suppressed)

Q2-2024 cohort (3 loans, origination 2024-04-01):
  loan_d: 3 months, no events
  loan_e: 1 month, defaults at MOB 1
  loan_f: 2 months, prepays at MOB 2 (no prior default)

Q3-2024 cohort (10 loans, origination 2024-07-01):
  loan_h through loan_q: 1 month each, no events
```

Selected output rows:

```
origination_cohort | months_on_book | cohort_loan_count | cumulative_default_count | cumulative_prepayment_count | cumulative_default_rate | is_censored
2024-01-01         | 1              | 4                 | 0                        | 0                           | 0.000000                | true
2024-01-01         | 2              | 4                 | 2                        | 0                           | 0.500000                | true
2024-01-01         | 3              | 4                 | 2                        | 1                           | 0.500000                | true
2024-04-01         | 1              | 3                 | 1                        | 0                           | 0.333333                | true
2024-04-01         | 2              | 3                 | 1                        | 1                           | 0.333333                | true
2024-07-01         | 1              | 10                | 0                        | 0                           | 0.000000                | false
```

Note: loan_g defaults at MOB 2 and has a prepayment flag at MOB 3, but `cumulative_prepayment_count`
at MOB 3 is 1 (loan_c only) — loan_g's prepayment is suppressed because `default_mob is not null`.

Q3 cohort is not censored at MOB 1 because `loans_at_risk_count = 10 >= censored_threshold = 10`.

## Caller example

```sql
{{ config(materialized='table') }}

select
    origination_cohort,
    months_on_book,
    cohort_loan_count,
    cohort_principal,
    cumulative_default_count,
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

## Edge cases and assumptions

- **Cohort max MOB is the input data's horizon.** The `mob_spine` generates MOBs 1 through
  `max(total_mob)` for each cohort. If a cohort's longest-observed loan runs to MOB 24, the
  output has 24 rows for that cohort. Loans with fewer observed rows still contribute their
  event flags up to MOB 24.

- **Origination balance = first observed period.** `cohort_principal` uses the beginning
  balance at each loan's earliest `performance_date`, not the minimum balance. For amortizing
  loans these differ; the first period's balance best represents origination exposure.

- **No status filter.** All rows in the relation participate in MOB calculation. If your
  data contains written-off rows, filter them at the staging layer.

- **Prepayment denominator is non-defaulted, not at-risk.** `cumulative_prepayment_rate =
  cumulative_prepayment_count / (cohort_loan_count - cumulative_default_count)`. A loan that
  prepaid early does not reduce this denominator — the rate answers "of loans that haven't
  defaulted, how many have prepaid?"

- **Both flags on the same row.** If `is_default = true` and `is_prepayment = true` on the
  same row, the loan's `default_mob` is set (it defaults), and the prepayment event is
  suppressed by the `CASE WHEN default_mob IS NULL` guard. Only default counts are incremented.

- **Cohort granularity of 'month' vs 'quarter'.** `cohort_granularity='month'` truncates
  `origination_date` to the first of the origination month. `'quarter'` truncates to the
  first of the origination quarter. The choice affects cohort sizes and curve smoothness;
  quarterly cohorts are the default to match typical consumer-lending reporting cadences.
