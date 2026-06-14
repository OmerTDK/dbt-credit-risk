# `cpr_smm`

Computes prepayment speed curves — Single Monthly Mortality (SMM) and annualized Conditional
Prepayment Rate (CPR) — from a caller-supplied loan-performance relation. Returns one row per
`(origination_cohort, months_on_book)` combination, with pool balances, loan counts, and
both prepayment speed metrics.

## Signature

```jinja
{% macro cpr_smm(
    relation,
    loan_id_col,
    origination_date_col,
    performance_date_col,
    beginning_balance_col,
    prepaid_amount_col,
    is_active_col,
    is_prepayment_col,
    cohort_granularity='quarter'
) %}
```

## Arguments

| Argument | Required | Type | Description |
|----------|----------|------|-------------|
| `relation` | yes | dbt Relation | The caller's `ref()` or `source()`. One row per `(loan_id, performance_date)`. |
| `loan_id_col` | yes | string | Physical column name for the loan natural key. |
| `origination_date_col` | yes | string | Physical column name for the loan origination DATE. Must not be null. Used to assign each loan to a cohort. |
| `performance_date_col` | yes | string | Physical column name for the performance period DATE. Must not be null. `(loan_id, performance_date)` must be unique across the input. |
| `beginning_balance_col` | yes | string | Physical column name for the beginning-of-period balance (numeric, >= 0). For performing (non-prepaying) active loans, this balance contributes to the denominator pool. |
| `prepaid_amount_col` | yes | string | Physical column name for the unscheduled principal repaid this period. This is the prepayment amount, not the total payment. Must be numeric and non-negative. |
| `is_active_col` | yes | string | Physical column name for the boolean active-loan flag. Inactive loans (closed, written off) are excluded from all pool calculations. |
| `is_prepayment_col` | yes | string | Physical column name for the boolean prepayment-event flag. A row where `is_prepayment = true` contributes `prepaid_amount` to the numerator and is excluded from the performing-pool denominator. |
| `cohort_granularity` | no | string | `'month'` or `'quarter'`. Controls how `origination_date` is truncated into `origination_cohort`. Default `'quarter'`. |

## Input contract

The relation must satisfy all of the following. Violations raise a runtime division-by-zero
error via the `contract_assertions` CTE:

- `(loan_id_col, performance_date_col)` must be unique. Duplicate pairs cause grain violation.
- `origination_date_col` must not be null for any row.
- `performance_date_col` must not be null for any row.
- `beginning_balance_col` must be >= 0 for all rows. Negative balances cause assertion failure.

**Grain:** one row per `(loan_id, performance_date)`. All rows participate, but only rows where
`is_active = true` contribute to pool metrics. Rows where `is_active = false` are read for
contract validation (duplicate grain, null date checks) but excluded from `pool_metrics`.

**SMM denominator convention (conditional pool):** `performing_pool_balance` is the sum of
`beginning_balance` for rows where `is_active = true AND is_prepayment = false`. Prepaying
loans are excluded from the performing pool and counted separately. This is the conditional-pool
convention: SMM measures the fraction of the performing pool that prepaid, not the fraction of
the total pool. Callers coming from the ABS total-pool convention
(`SMM = prepaid / (performing + prepaid)`) will observe higher SMM values for the same input.

**`prepaid_amount_col` semantics:** this column must contain only the unscheduled (excess)
principal repaid in the period, not the total payment amount. If your source table stores
total payment, compute `total_payment - scheduled_principal` in your staging model before
calling this macro.

**Months-on-book calculation:** `(year_diff * 12) + month_diff + 1`. A loan originated
2024-01-01 with a performance row on 2024-01-01 is MOB 1; a row on 2024-02-01 is MOB 2.

## Output schema

| Column | Type | Description |
|--------|------|-------------|
| `origination_cohort` | DATE | First-of-month (monthly granularity) or first-of-quarter (quarterly granularity). |
| `months_on_book` | INTEGER | Months elapsed since origination, 1-indexed. |
| `performing_pool_balance` | DECIMAL(18,2) | Sum of `beginning_balance` for active, non-prepaying loans this period. The SMM denominator. |
| `prepaid_balance` | DECIMAL(18,2) | Sum of `prepaid_amount` for prepaying loans this period. The SMM numerator. |
| `eligible_loan_count` | INTEGER | Count of distinct active, non-prepaying loans this period. |
| `prepaying_loan_count` | INTEGER | Count of distinct prepaying loans this period. |
| `smm_rate` | DECIMAL(10,6) | `prepaid_balance / performing_pool_balance`. NULL when `performing_pool_balance = 0`. |
| `cpr_rate` | DECIMAL(10,6) | `1 - (1 - smm_rate)^12`. Annualized prepayment rate. NULL when `performing_pool_balance = 0`. |

**CPR formula:** `CPR = 1 - (1 - SMM)^12`. This is the standard monthly-to-annual
annualization. When `performing_pool_balance = 0`, `cpr_rate` is NULL (not 0) to avoid
implying a 0% CPR for a period where the denominator is undefined.

**Key invariant:** `CPR = 1 - (1 - SMM)^12` holds within floating-point tolerance of 0.000001
for all rows where `performing_pool_balance > 0`. Verified by `assert_cpr_smm_annualization`
in the integration-test suite.

## Worked example

Input (`loan_performance_cpr` seed, 14 rows, 6 loans, 2 cohorts):

```
Q1-2024 cohort (4 loans, origination 2024-01-01):
  loan_p1: 3 months; prepays 6000 at MOB 2 (beginning_balance 28000 at MOB 2)
  loan_p2: 3 months; no prepayment
  loan_p3: 3 months; no prepayment
  (loan_p4: 1 row at MOB 2 only; prepaid_amount=500 but is_prepayment=false — not counted)

Q2-2024 cohort (2 active loans, origination 2024-04-01):
  loan_q1: 2 months; prepays 5000 at MOB 1 (beginning_balance 25000 at MOB 1)
  loan_q2: 2 months; no prepayment
```

Selected output rows:

```
origination_cohort | months_on_book | performing_pool_balance | prepaid_balance | smm_rate | cpr_rate
2024-01-01         | 1              | 60000.00                | 0.00            | 0.000000 | 0.000000
2024-01-01         | 2              | 32000.00                | 6000.00         | 0.187500 | 0.917229
2024-01-01         | 3              | 46000.00                | 0.00            | 0.000000 | 0.000000
2024-04-01         | 1              | 15000.00                | 5000.00         | 0.333333 | 0.992293
2024-04-01         | 2              | 34000.00                | 0.00            | 0.000000 | 0.000000
```

At Q1-2024 MOB 1: `performing_pool_balance = 30000 + 20000 + 10000 = 60000` (3 non-prepaying
active loans). `prepaid_balance = 0`. SMM = 0.

At Q1-2024 MOB 2: loan_p1 prepays. `performing_pool_balance = 18000 + 9000 + 5000 = 32000`
(loan_p2, loan_p3, and loan_p4 active/non-prepaying). `prepaid_balance = 6000` (loan_p1).
SMM = 6000 / 32000 = 0.1875. CPR = 1 - (1 - 0.1875)^12 = 0.917229.

## Caller example

```sql
{{ config(materialized='table') }}

select
    origination_cohort,
    months_on_book,
    performing_pool_balance,
    prepaid_balance,
    eligible_loan_count,
    prepaying_loan_count,
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

## Edge cases and assumptions

- **Inactive loans are fully excluded.** Rows where `is_active_col = false` do not contribute
  to `performing_pool_balance`, `prepaid_balance`, `eligible_loan_count`, or
  `prepaying_loan_count`. They participate only in the contract-assertion CTEs.

- **A prepaying loan is excluded from the performing-pool denominator.** If a loan has
  `is_active = true` and `is_prepayment = true`, its `beginning_balance` goes into
  `prepaid_balance` computation (as a prepaying loan) and its balance is excluded from
  `performing_pool_balance`. This avoids double-counting.

- **`prepaid_amount = 0` with `is_prepayment = false` is a normal performing row.** The macro
  does not require `prepaid_amount > 0` on prepayment rows; the flag drives inclusion, not
  the amount. A row with `is_prepayment = true` and `prepaid_amount = 0` contributes 0 to
  `prepaid_balance` but is still counted in `prepaying_loan_count`.

- **Zero performing pool.** When all active loans in a cohort-MOB prepay simultaneously,
  `performing_pool_balance = 0`. `smm_rate` and `cpr_rate` are NULL (not 0) to signal an
  undefined rate, not a zero-prepayment period.

- **Cohort granularity of 'month' vs 'quarter'.** The same rule as `vintage_curve` applies:
  `'quarter'` truncates `origination_date` to the first of the quarter. Default is `'quarter'`.

- **Total-pool vs conditional-pool SMM.** This macro uses the conditional-pool denominator
  (standard in European consumer lending): `SMM = prepaid / performing_non_prepaying`. The
  ABS/US-agency total-pool convention (`SMM = prepaid / (performing + prepaid)`) gives a lower
  SMM for the same data. The denominator choice is documented here and in ADR-0002.

- **No output rows for cohort-MOBs with zero active loans.** If a cohort has no active
  (or prepaying) loans at a given MOB, that cohort-MOB combination produces no row in the
  output. Callers who need a spine of all possible MOBs should generate one in their wrapping
  model and left-join to the macro output.
