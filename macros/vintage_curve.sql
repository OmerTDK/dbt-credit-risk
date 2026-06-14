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

{%- set reserved_output_cols = [
    'origination_cohort',
    'months_on_book',
    'cohort_loan_count',
    'cohort_principal',
    'cumulative_default_count',
    'cumulative_prepayment_count',
    'surviving_non_defaulted_count',
    'loans_at_risk_count',
    'cumulative_default_rate',
    'cumulative_prepayment_rate',
    'is_censored'
] -%}

{%- if relation is none -%}
    {{ exceptions.raise_compiler_error(
        "credit_risk.vintage_curve: 'relation' is required. Pass a dbt ref() or source() result."
    ) }}
{%- endif -%}

{%- if loan_id_col == '' or loan_id_col is none -%}
    {{ exceptions.raise_compiler_error(
        "credit_risk.vintage_curve: 'loan_id_col' is required — pass the column name for the loan natural key."
    ) }}
{%- endif -%}

{%- if origination_date_col == '' or origination_date_col is none -%}
    {{ exceptions.raise_compiler_error(
        "credit_risk.vintage_curve: 'origination_date_col' is required — pass the column name for the loan origination DATE."
    ) }}
{%- endif -%}

{%- if performance_date_col == '' or performance_date_col is none -%}
    {{ exceptions.raise_compiler_error(
        "credit_risk.vintage_curve: 'performance_date_col' is required — pass the column name for the performance period DATE."
    ) }}
{%- endif -%}

{%- if is_default_col == '' or is_default_col is none -%}
    {{ exceptions.raise_compiler_error(
        "credit_risk.vintage_curve: 'is_default_col' is required — pass the column name for the boolean default flag."
    ) }}
{%- endif -%}

{%- if is_prepayment_col == '' or is_prepayment_col is none -%}
    {{ exceptions.raise_compiler_error(
        "credit_risk.vintage_curve: 'is_prepayment_col' is required — pass the column name for the boolean prepayment flag."
    ) }}
{%- endif -%}

{%- if balance_col == '' or balance_col is none -%}
    {{ exceptions.raise_compiler_error(
        "credit_risk.vintage_curve: 'balance_col' is required — pass the column name for the beginning-of-period balance."
    ) }}
{%- endif -%}

{%- if cohort_granularity not in ('month', 'quarter') -%}
    {{ exceptions.raise_compiler_error(
        "credit_risk.vintage_curve: 'cohort_granularity' must be 'month' or 'quarter', got: '" ~ cohort_granularity ~ "'."
    ) }}
{%- endif -%}

{%- if censored_threshold is not number or censored_threshold < 1 or censored_threshold != censored_threshold | int -%}
    {{ exceptions.raise_compiler_error(
        "credit_risk.vintage_curve: 'censored_threshold' must be a positive integer, got: " ~ censored_threshold ~ "."
    ) }}
{%- endif -%}

with constants as (
    select {{ censored_threshold }} as censored_threshold
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
        1 / case when grain_violation_count.duplicate_pair_count > 0 then 0 else 1 end
            as _assert_grain
    from null_origination_count, null_performance_count, grain_violation_count
),

loan_events as (
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
        cast({{ is_default_col }} as boolean) as is_default,
        cast({{ is_prepayment_col }} as boolean) as is_prepayment,
        cast({{ balance_col }} as double) as beginning_balance,
        cast(
            (cast(extract(year from cast({{ performance_date_col }} as date)) as integer)
                - cast(extract(year from cast({{ origination_date_col }} as date)) as integer)) * 12
            + cast(extract(month from cast({{ performance_date_col }} as date)) as integer)
            - cast(extract(month from cast({{ origination_date_col }} as date)) as integer)
            + 1
            as integer
        ) as months_on_book,
        contract_assertions._assert_grain as _assertion_pass
    from {{ relation }}
    cross join contract_assertions
),

first_period_per_loan as (
    select loan_id, min(performance_date) as first_performance_date
    from loan_events
    group by loan_id
),

loan_origination_info as (
    select
        loan_events.loan_id,
        loan_events.origination_cohort,
        loan_events.beginning_balance as origination_balance,
        min(
            case when loan_events.is_default
                then loan_events.months_on_book
            end
        ) as default_mob,
        min(
            case when loan_events.is_prepayment
                then loan_events.months_on_book
            end
        ) as prepayment_mob_raw,
        max(loan_events.months_on_book) as total_mob
    from loan_events
    inner join first_period_per_loan
        on loan_events.loan_id = first_period_per_loan.loan_id
        and loan_events.performance_date = first_period_per_loan.first_performance_date
    group by
        loan_events.loan_id,
        loan_events.origination_cohort,
        loan_events.beginning_balance
),

loan_totals as (
    select
        loan_events.loan_id,
        max(loan_events.months_on_book) as total_mob,
        min(
            case when loan_events.is_default
                then loan_events.months_on_book
            end
        ) as default_mob,
        min(
            case when loan_events.is_prepayment
                then loan_events.months_on_book
            end
        ) as prepayment_mob_raw
    from loan_events
    group by loan_events.loan_id
),

loan_summary as (
    select
        loan_origination_info.loan_id,
        loan_origination_info.origination_cohort,
        loan_origination_info.origination_balance,
        loan_totals.default_mob,
        case
            when loan_totals.default_mob is null
                then loan_totals.prepayment_mob_raw
        end as prepayment_mob,
        loan_totals.total_mob
    from loan_origination_info
    inner join loan_totals
        on loan_origination_info.loan_id = loan_totals.loan_id
),

cohort_sizes as (
    select
        loan_summary.origination_cohort,
        count(distinct loan_summary.loan_id) as cohort_loan_count,
        sum(loan_summary.origination_balance) as cohort_principal,
        max(loan_summary.total_mob) as max_mob
    from loan_summary
    group by
        loan_summary.origination_cohort
),

mob_spine as (
    select
        cohort_sizes.origination_cohort,
        mob_numbers.months_on_book
    from cohort_sizes
    cross join (
        select unnest(range(1, 121)) as months_on_book
    ) as mob_numbers
    where mob_numbers.months_on_book <= cohort_sizes.max_mob
),

loan_milestone_flags as (
    select
        mob_spine.origination_cohort,
        mob_spine.months_on_book,
        cast(
            loan_summary.default_mob is not null
            and loan_summary.default_mob <= mob_spine.months_on_book
            as integer
        ) as has_defaulted_by_mob,
        cast(
            loan_summary.prepayment_mob is not null
            and loan_summary.prepayment_mob <= mob_spine.months_on_book
            as integer
        ) as has_prepaid_non_defaulted_by_mob
    from loan_summary
    inner join mob_spine
        on loan_summary.origination_cohort = mob_spine.origination_cohort
),

event_flags as (
    select
        loan_milestone_flags.origination_cohort,
        loan_milestone_flags.months_on_book,
        sum(loan_milestone_flags.has_defaulted_by_mob) as cumulative_default_count,
        sum(loan_milestone_flags.has_prepaid_non_defaulted_by_mob) as cumulative_prepayment_count
    from loan_milestone_flags
    group by
        loan_milestone_flags.origination_cohort,
        loan_milestone_flags.months_on_book
)

select
    event_flags.origination_cohort,
    cast(event_flags.months_on_book as integer) as months_on_book,
    cast(cohort_sizes.cohort_loan_count as integer) as cohort_loan_count,
    cast(cohort_sizes.cohort_principal as decimal(18, 2)) as cohort_principal,
    cast(event_flags.cumulative_default_count as integer) as cumulative_default_count,
    cast(event_flags.cumulative_prepayment_count as integer) as cumulative_prepayment_count,
    cast(
        cohort_sizes.cohort_loan_count - event_flags.cumulative_default_count
        as integer
    ) as surviving_non_defaulted_count,
    cast(
        cohort_sizes.cohort_loan_count
        - event_flags.cumulative_default_count
        - event_flags.cumulative_prepayment_count
        as integer
    ) as loans_at_risk_count,
    cast(
        cast(event_flags.cumulative_default_count as double)
        / nullif(cohort_sizes.cohort_loan_count, 0)
        as decimal(10, 6)
    ) as cumulative_default_rate,
    cast(
        cast(event_flags.cumulative_prepayment_count as double)
        / nullif(
            cohort_sizes.cohort_loan_count - event_flags.cumulative_default_count,
            0
        )
        as decimal(10, 6)
    ) as cumulative_prepayment_rate,
    (
        cohort_sizes.cohort_loan_count
        - event_flags.cumulative_default_count
        - event_flags.cumulative_prepayment_count
    ) < constants.censored_threshold as is_censored
from event_flags
inner join cohort_sizes
    on event_flags.origination_cohort = cohort_sizes.origination_cohort
cross join constants

{% endmacro %}
