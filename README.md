# dbt-credit-risk

Credit risk analytics macros for dbt: roll-rate matrices, vintage curves, and CPR/SMM prepayment curves.

[![CI](https://github.com/OmerTDK/dbt-credit-risk/actions/workflows/ci.yml/badge.svg)](https://github.com/OmerTDK/dbt-credit-risk/actions/workflows/ci.yml)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![dbt version](https://img.shields.io/badge/dbt-%3E%3D1.8.0-orange)](dbt_project.yml)

---

## Installation

Add to your project's `packages.yml`:

```yaml
packages:
  - git: "https://github.com/OmerTDK/dbt-credit-risk"
    revision: v0.1.0
```

Then run:

```bash
dbt deps
```

No external dependencies. Requires dbt >= 1.8.0.

> **dbt Hub listing pending.** Once the repo is public and the Hub PR is merged, the install will be:
> ```yaml
> packages:
>   - package: omertdk/credit_risk
>     version: [">=0.1.0", "<0.2.0"]
> ```

---

## Macros

### `credit_risk.roll_rate_matrix`

Computes a delinquency state-transition matrix from a monthly loan-performance relation.

**Signature**

```jinja
{{ credit_risk.roll_rate_matrix(
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
) }}
```

| Argument | Type | Default | Description |
|---|---|---|---|
| `relation` | relation | required | `ref()` or `source()` — one row per `(loan_id, period)` per active loan |
| `loan_id_col` | string | required | Loan natural key column |
| `period_col` | string | required | Performance period DATE column (macro DATE_TRUNCs to month) |
| `bucket_col` | string | required | Delinquency state label column (`'current'`, `'dpd_30'`, etc.) |
| `balance_col` | string | required | Beginning-of-period balance (NUMERIC, >= 0, non-null for active rows) |
| `status_col` | string | required | Active/inactive status flag column |
| `active_status_value` | string | required | Value of `status_col` that marks a loan as at-risk |
| `segment_cols` | list | `[]` | Optional list of columns to group by (e.g. `['product_type']`) |
| `period_length_months` | integer | `1` | Months between consecutive observation periods |
| `minimum_cell_count` | integer | `10` | Threshold below which a cell is flagged `is_low_count_cell = true` |

**Required input columns**

| Column | Type | Contract |
|---|---|---|
| `loan_id_col` | VARCHAR | `(loan_id, period)` unique for active rows |
| `period_col` | DATE | Non-null for active rows |
| `bucket_col` | VARCHAR | Non-null for active rows recommended |
| `balance_col` | NUMERIC | >= 0, non-null for active rows |
| `status_col` | VARCHAR | Identifies at-risk population |

**Example call**

```sql
{{ config(materialized='table') }}

select *
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

**Output schema**

| Column | Type | Description |
|---|---|---|
| `observation_period` | DATE | The from-period (start of month) |
| `period_length_months` | INTEGER | Months between periods |
| `from_bucket` | VARCHAR | Delinquency state at start of period |
| `to_bucket` | VARCHAR | Delinquency state at start of next period |
| `transition_loan_count` | INTEGER | Loans that moved from `from_bucket` to `to_bucket` |
| `at_risk_loan_count` | INTEGER | Loans in `from_bucket` with a valid next-period row |
| `transition_balance` | DECIMAL(18,2) | Sum of beginning balances for transitioning loans |
| `at_risk_balance` | DECIMAL(18,2) | Sum of beginning balances for at-risk loans |
| `transition_rate` | DECIMAL(10,6) | `transition_loan_count / at_risk_loan_count` |
| `transition_balance_rate` | DECIMAL(10,6) | `transition_balance / at_risk_balance` |
| `is_low_count_cell` | BOOLEAN | True when `at_risk_loan_count < minimum_cell_count` |

Segment columns (from `segment_cols`) appear as leading columns before `observation_period`.

Full contract and worked example: [`docs/macros/roll_rate_matrix.md`](docs/macros/roll_rate_matrix.md)

---

### `credit_risk.vintage_curve`

Computes cumulative default and prepayment rates by origination cohort and months-on-book (MOB).

**Signature**

```jinja
{{ credit_risk.vintage_curve(
    relation,
    loan_id_col,
    origination_date_col,
    performance_date_col,
    is_default_col,
    is_prepayment_col,
    balance_col,
    cohort_granularity='quarter',
    censored_threshold=10
) }}
```

| Argument | Type | Default | Description |
|---|---|---|---|
| `relation` | relation | required | `ref()` or `source()` — one row per `(loan_id, performance_date)` |
| `loan_id_col` | string | required | Loan natural key column |
| `origination_date_col` | string | required | Loan origination DATE column |
| `performance_date_col` | string | required | Performance period DATE column |
| `is_default_col` | string | required | Boolean — true on first period the loan enters default |
| `is_prepayment_col` | string | required | Boolean — true on period of full prepayment (suppressed if already defaulted) |
| `balance_col` | string | required | Beginning-of-period balance; first period's value used as origination balance |
| `cohort_granularity` | string | `'quarter'` | Cohort grouping: `'month'` or `'quarter'` |
| `censored_threshold` | integer | `10` | Minimum `loans_at_risk_count` below which `is_censored = true` |

**Required input columns**

| Column | Type | Contract |
|---|---|---|
| `loan_id_col` | VARCHAR | `(loan_id, performance_date)` unique |
| `origination_date_col` | DATE | Non-null |
| `performance_date_col` | DATE | Non-null |
| `is_default_col` | BOOLEAN | True on the first default period only |
| `is_prepayment_col` | BOOLEAN | True on prepayment period; mutually exclusive with default |
| `balance_col` | NUMERIC | First observed period's value used as origination balance |

**Example call**

```sql
{{ config(materialized='table') }}

select *
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

**Output schema**

| Column | Type | Description |
|---|---|---|
| `origination_cohort` | DATE | Cohort start date (month or quarter truncated) |
| `months_on_book` | INTEGER | Months since origination (1-indexed) |
| `cohort_loan_count` | INTEGER | Total loans in cohort |
| `cohort_principal` | DECIMAL(18,2) | Sum of origination balances across cohort |
| `cumulative_default_count` | INTEGER | Loans defaulted by this MOB |
| `cumulative_prepayment_count` | INTEGER | Loans prepaid (non-defaulted) by this MOB |
| `surviving_non_defaulted_count` | INTEGER | `cohort_loan_count - cumulative_default_count` |
| `loans_at_risk_count` | INTEGER | `cohort_loan_count - defaults - prepayments` |
| `cumulative_default_rate` | DECIMAL(10,6) | `cumulative_default_count / cohort_loan_count` |
| `cumulative_prepayment_rate` | DECIMAL(10,6) | `cumulative_prepayment_count / surviving_non_defaulted_count` |
| `is_censored` | BOOLEAN | True when `loans_at_risk_count < censored_threshold` |

Full contract and worked example: [`docs/macros/vintage_curve.md`](docs/macros/vintage_curve.md)

---

### `credit_risk.cpr_smm`

Computes Single Monthly Mortality (SMM) and annualized Constant Prepayment Rate (CPR) by origination cohort and MOB. Uses the **conditional-pool** denominator (European consumer-lending convention): `SMM = prepaid_balance / performing_pool_balance`.

**Signature**

```jinja
{{ credit_risk.cpr_smm(
    relation,
    loan_id_col,
    origination_date_col,
    performance_date_col,
    beginning_balance_col,
    prepaid_amount_col,
    is_active_col,
    is_prepayment_col,
    cohort_granularity='quarter'
) }}
```

| Argument | Type | Default | Description |
|---|---|---|---|
| `relation` | relation | required | `ref()` or `source()` — one row per `(loan_id, performance_date)` |
| `loan_id_col` | string | required | Loan natural key column |
| `origination_date_col` | string | required | Loan origination DATE column |
| `performance_date_col` | string | required | Performance period DATE column |
| `beginning_balance_col` | string | required | Beginning-of-period balance (NUMERIC, >= 0) |
| `prepaid_amount_col` | string | required | Unscheduled principal repaid this period; 0 for non-prepaying rows |
| `is_active_col` | string | required | Boolean — true for loans in the performing or prepaying pool |
| `is_prepayment_col` | string | required | Boolean — true on period of a prepayment event |
| `cohort_granularity` | string | `'quarter'` | Cohort grouping: `'month'` or `'quarter'` |

**Required input columns**

| Column | Type | Contract |
|---|---|---|
| `loan_id_col` | VARCHAR | `(loan_id, performance_date)` unique |
| `origination_date_col` | DATE | Non-null |
| `performance_date_col` | DATE | Non-null |
| `beginning_balance_col` | NUMERIC | >= 0 |
| `prepaid_amount_col` | NUMERIC | 0 for non-prepaying rows |
| `is_active_col` | BOOLEAN | False for closed/written-off loans |
| `is_prepayment_col` | BOOLEAN | True on the period of a prepayment event |

**Example call**

```sql
{{ config(materialized='table') }}

select *
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

**Output schema**

| Column | Type | Description |
|---|---|---|
| `origination_cohort` | DATE | Cohort start date (month or quarter truncated) |
| `months_on_book` | INTEGER | Months since origination (1-indexed) |
| `performing_pool_balance` | DECIMAL(18,2) | Sum of `beginning_balance` for active non-prepaying loans (SMM denominator) |
| `prepaid_balance` | DECIMAL(18,2) | Sum of `prepaid_amount` for active prepaying loans (SMM numerator) |
| `eligible_loan_count` | INTEGER | Active non-prepaying loan count |
| `prepaying_loan_count` | INTEGER | Active prepaying loan count |
| `smm_rate` | DECIMAL(10,6) | `prepaid_balance / performing_pool_balance` |
| `cpr_rate` | DECIMAL(10,6) | `1 - (1 - smm_rate)^12`; NULL when `performing_pool_balance = 0` |

> **SMM convention:** this macro uses the conditional-pool denominator (non-prepaying active loans only), which is the European consumer-lending convention. The US ABS convention (`SMM = prepaid / total_pool`) produces lower values for the same portfolio. See [`docs/macros/cpr_smm.md`](docs/macros/cpr_smm.md).

Full contract and worked example: [`docs/macros/cpr_smm.md`](docs/macros/cpr_smm.md)

---

## Supported adapters

| Adapter | Status |
|---|---|
| DuckDB | CI-tested on every PR |
| BigQuery | Compatible — adapter helpers written and verified |

The three adapter-specific functions (`DATE_TRUNC`, `INTERVAL` arithmetic, `GENERATE_ARRAY` / `range()`) are isolated in `macros/utils/`. All other SQL is ANSI-portable.

---

## Design decisions

See [`docs/adr/`](docs/adr/) for the full decision log.

| ADR | Decision |
|---|---|
| [ADR-0001](docs/adr/0001-roll-rate-macro-api-and-contract.md) | Roll-rate API, three-layer validation, **gap-continuity INNER JOIN guard** |
| [ADR-0002](docs/adr/0002-vintage-curve-and-cpr-smm-macro-design.md) | Origination balance, MOB propagation, conditional-pool SMM |
| [ADR-0003](docs/adr/0003-documentation-and-input-contract-approach.md) | Prose contracts vs. dbt enforced contracts, doc-block placement |
| [ADR-0004](docs/adr/0004-hub-publish-and-release-strategy.md) | Semver v0.1.0, Hub publication flow, `require-dbt-version` floor |

### The hardest design decision: gap-continuity in `roll_rate_matrix`

The `at_risk_denominator` CTE uses `INNER JOIN` — not `LEFT JOIN` — when joining a loan's current period to its next period. A loan with no row in the active population for the next period (paid off, written off, or gapped) cannot satisfy the join and is excluded from the denominator.

With a `LEFT JOIN`, the output has the same shape and plausible-looking counts — just wrong. The inflated denominator deflates all transition rates for that period/bucket pair and is invisible in a naively constructed test. The integration test `assert_gap_exclusion.sql` is written specifically to catch it: it asserts that `loan_c` (inactive in February) is excluded from the January at-risk denominator, producing `at_risk_loan_count = 3` not 4.

Full tradeoff analysis: [ADR-0001](docs/adr/0001-roll-rate-macro-api-and-contract.md).

---

## Contributing / Development

### Prerequisites

- Python 3.10+
- [`uv`](https://github.com/astral-sh/uv) for dependency management

### Setup

```bash
git clone https://github.com/OmerTDK/dbt-credit-risk
cd dbt-credit-risk
uv sync
```

### Run the full CI suite locally

```bash
make ci          # ruff + SQLFluff lint, then 15 pytest tests (includes dbt build + 15 dbt data tests)
```

Individual targets:

```bash
make lint        # ruff check/format + SQLFluff lint on macros/
make test        # pytest only (triggers dbt build via subprocess)
make dbt-build   # dbt build inside integration_tests/ directly
make dbt-parse   # parse only — no warehouse round-trip
```

### Integration tests

The integration test harness in `integration_tests/` is a self-contained dbt project using DuckDB `:memory:` — no credentials needed. Seeds provide hand-verified input data; singular tests assert row-for-row correctness against hand-computed expected outputs.

```
integration_tests/
├── seeds/                          # Input fixtures + expected output seeds
├── models/                         # One model per macro call
└── tests/                          # Singular tests (full-outer-join row-for-row assertions)
```

CI runs `make ci` on every PR.

---

## License

Apache-2.0. See [LICENSE](LICENSE).
