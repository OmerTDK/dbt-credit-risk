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

{%- set reserved_output_cols = [
    'origination_cohort',
    'months_on_book',
    'performing_pool_balance',
    'prepaid_balance',
    'eligible_loan_count',
    'prepaying_loan_count',
    'smm_rate',
    'cpr_rate'
] -%}

{%- set caller_col_args = [
    loan_id_col,
    origination_date_col,
    performance_date_col,
    beginning_balance_col,
    prepaid_amount_col,
    is_active_col,
    is_prepayment_col
] -%}
{%- for col in caller_col_args -%}
    {%- if col in reserved_output_cols -%}
        {{ exceptions.raise_compiler_error(
            "credit_risk.cpr_smm: column argument '" ~ col ~ "' collides with a reserved output column name. Rename the source column or use an alias."
        ) }}
    {%- endif -%}
{%- endfor -%}

{%- if relation is none -%}
    {{ exceptions.raise_compiler_error(
        "credit_risk.cpr_smm: 'relation' is required. Pass a dbt ref() or source() result."
    ) }}
{%- endif -%}

{%- if loan_id_col == '' or loan_id_col is none -%}
    {{ exceptions.raise_compiler_error(
        "credit_risk.cpr_smm: 'loan_id_col' is required — pass the column name for the loan natural key."
    ) }}
{%- endif -%}

{%- if origination_date_col == '' or origination_date_col is none -%}
    {{ exceptions.raise_compiler_error(
        "credit_risk.cpr_smm: 'origination_date_col' is required — pass the column name for the loan origination DATE."
    ) }}
{%- endif -%}

{%- if performance_date_col == '' or performance_date_col is none -%}
    {{ exceptions.raise_compiler_error(
        "credit_risk.cpr_smm: 'performance_date_col' is required — pass the column name for the performance period DATE."
    ) }}
{%- endif -%}

{%- if beginning_balance_col == '' or beginning_balance_col is none -%}
    {{ exceptions.raise_compiler_error(
        "credit_risk.cpr_smm: 'beginning_balance_col' is required — pass the column name for the beginning-of-period balance."
    ) }}
{%- endif -%}

{%- if prepaid_amount_col == '' or prepaid_amount_col is none -%}
    {{ exceptions.raise_compiler_error(
        "credit_risk.cpr_smm: 'prepaid_amount_col' is required — pass the column name for the unscheduled principal repaid this period."
    ) }}
{%- endif -%}

{%- if is_active_col == '' or is_active_col is none -%}
    {{ exceptions.raise_compiler_error(
        "credit_risk.cpr_smm: 'is_active_col' is required — pass the column name for the boolean active-loan flag."
    ) }}
{%- endif -%}

{%- if is_prepayment_col == '' or is_prepayment_col is none -%}
    {{ exceptions.raise_compiler_error(
        "credit_risk.cpr_smm: 'is_prepayment_col' is required — pass the column name for the boolean prepayment-event flag."
    ) }}
{%- endif -%}

{%- if cohort_granularity not in ('month', 'quarter') -%}
    {{ exceptions.raise_compiler_error(
        "credit_risk.cpr_smm: 'cohort_granularity' must be 'month' or 'quarter', got: '" ~ cohort_granularity ~ "'."
    ) }}
{%- endif -%}

with constants as (
    select 12 as months_per_year
),

null_origination_count as (
    select count(*) as null_count
    from {{ relation }}
    where {{ origination_date_col }} is null
),

null_performance_count as (
    select count(*) as null_count
    from {{ relation }}
    where {{ performance_date_col }} is null
),

negative_balance_count as (
    select count(*) as negative_count
    from {{ relation }}
    where {{ beginning_balance_col }} < 0
),

duplicate_grain_pairs as (
    select {{ loan_id_col }}, {{ performance_date_col }}, count(*) as row_count
    from {{ relation }}
    group by {{ loan_id_col }}, {{ performance_date_col }}
    having count(*) > 1
),

grain_violation_count as (
    select count(*) as duplicate_pair_count
    from duplicate_grain_pairs
),

contract_assertions as (
    select
        1 / case when null_origination_count.null_count > 0 then 0 else 1 end
            as _assert_origination_not_null,
        1 / case when null_performance_count.null_count > 0 then 0 else 1 end
            as _assert_performance_not_null,
        1 / case when negative_balance_count.negative_count > 0 then 0 else 1 end
            as _assert_balance_non_negative,
        1 / case when grain_violation_count.duplicate_pair_count > 0 then 0 else 1 end
            as _assert_grain
    from null_origination_count, null_performance_count, negative_balance_count, grain_violation_count
),

loan_periods as (
    select
        {{ loan_id_col }} as loan_id,
        cast(
            {% if cohort_granularity == 'month' %}
                {{ _date_trunc_month(origination_date_col) }}
            {% else %}
                {{ _date_trunc_quarter(origination_date_col) }}
            {% endif %}
            as date
        ) as origination_cohort,
        cast({{ origination_date_col }} as date) as origination_date,
        cast({{ performance_date_col }} as date) as performance_date,
        cast({{ beginning_balance_col }} as double) as beginning_balance,
        cast({{ prepaid_amount_col }} as double) as prepaid_amount,
        cast({{ is_active_col }} as boolean) as is_active,
        cast({{ is_prepayment_col }} as boolean) as is_prepayment,
        contract_assertions._assert_origination_not_null as _assertion_pass
    from {{ relation }}
    cross join contract_assertions
),

months_on_book_computed as (
    select
        loan_periods.loan_id,
        loan_periods.origination_cohort,
        loan_periods.performance_date,
        loan_periods.beginning_balance,
        loan_periods.prepaid_amount,
        loan_periods.is_active,
        loan_periods.is_prepayment,
        cast(
            (cast(extract(year from loan_periods.performance_date) as integer)
                - cast(extract(year from loan_periods.origination_date) as integer)) * 12
            + cast(extract(month from loan_periods.performance_date) as integer)
            - cast(extract(month from loan_periods.origination_date) as integer)
            + 1
            as integer
        ) as months_on_book
    from loan_periods
),

pool_metrics as (
    select
        months_on_book_computed.origination_cohort,
        months_on_book_computed.months_on_book,
        sum(
            case
                when months_on_book_computed.is_active
                    and not months_on_book_computed.is_prepayment
                    then months_on_book_computed.beginning_balance
                else 0
            end
        ) as performing_pool_balance,
        sum(
            case when months_on_book_computed.is_prepayment
                then months_on_book_computed.prepaid_amount
                else 0
            end
        ) as prepaid_balance,
        count(
            distinct case
                when months_on_book_computed.is_active
                    and not months_on_book_computed.is_prepayment
                    then months_on_book_computed.loan_id
            end
        ) as eligible_loan_count,
        count(
            distinct case
                when months_on_book_computed.is_prepayment
                    then months_on_book_computed.loan_id
            end
        ) as prepaying_loan_count
    from months_on_book_computed
    group by
        months_on_book_computed.origination_cohort,
        months_on_book_computed.months_on_book
)

select
    pool_metrics.origination_cohort,
    pool_metrics.months_on_book,
    cast(pool_metrics.performing_pool_balance as decimal(18, 2)) as performing_pool_balance,
    cast(pool_metrics.prepaid_balance as decimal(18, 2)) as prepaid_balance,
    cast(pool_metrics.eligible_loan_count as integer) as eligible_loan_count,
    cast(pool_metrics.prepaying_loan_count as integer) as prepaying_loan_count,
    cast(
        cast(pool_metrics.prepaid_balance as double)
        / nullif(pool_metrics.performing_pool_balance, 0)
        as decimal(10, 6)
    ) as smm_rate,
    case
        when pool_metrics.performing_pool_balance = 0 then null
        else cast(
            1.0 - power(
                1.0 - cast(pool_metrics.prepaid_balance as double)
                / nullif(pool_metrics.performing_pool_balance, 0),
                constants.months_per_year
            )
            as decimal(10, 6)
        )
    end as cpr_rate
from pool_metrics
cross join constants

{% endmacro %}
