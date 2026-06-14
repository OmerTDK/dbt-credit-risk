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

{%- set reserved_output_cols = [
    'observation_period',
    'from_bucket',
    'to_bucket',
    'transition_loan_count',
    'at_risk_loan_count',
    'transition_balance',
    'at_risk_balance',
    'transition_rate',
    'transition_balance_rate',
    'is_low_count_cell',
    'period_length_months'
] -%}

{%- if relation is none -%}
    {{ exceptions.raise_compiler_error(
        "credit_risk.roll_rate_matrix: 'relation' is required. Pass a dbt ref() or source() result."
    ) }}
{%- endif -%}

{%- if loan_id_col == '' or loan_id_col is none -%}
    {{ exceptions.raise_compiler_error(
        "credit_risk.roll_rate_matrix: 'loan_id_col' is required — pass the column name for the loan natural key."
    ) }}
{%- endif -%}

{%- if period_col == '' or period_col is none -%}
    {{ exceptions.raise_compiler_error(
        "credit_risk.roll_rate_matrix: 'period_col' is required — pass the column name for the performance period DATE."
    ) }}
{%- endif -%}

{%- if bucket_col == '' or bucket_col is none -%}
    {{ exceptions.raise_compiler_error(
        "credit_risk.roll_rate_matrix: 'bucket_col' is required — pass the column name for the delinquency state label."
    ) }}
{%- endif -%}

{%- if balance_col == '' or balance_col is none -%}
    {{ exceptions.raise_compiler_error(
        "credit_risk.roll_rate_matrix: 'balance_col' is required — pass the column name for the beginning-of-period balance."
    ) }}
{%- endif -%}

{%- if status_col == '' or status_col is none -%}
    {{ exceptions.raise_compiler_error(
        "credit_risk.roll_rate_matrix: 'status_col' is required — pass the column name for the active/inactive status."
    ) }}
{%- endif -%}

{%- if active_status_value == '' or active_status_value is none -%}
    {{ exceptions.raise_compiler_error(
        "credit_risk.roll_rate_matrix: 'active_status_value' is required — pass the string value that marks a loan as at-risk."
    ) }}
{%- endif -%}

{%- if segment_cols is string -%}
    {{ exceptions.raise_compiler_error(
        "credit_risk.roll_rate_matrix: 'segment_cols' must be a list, got a string. Did you mean ['{{ segment_cols }}']?"
    ) }}
{%- endif -%}

{%- if period_length_months is not number or period_length_months < 1 or period_length_months != period_length_months | int -%}
    {{ exceptions.raise_compiler_error(
        "credit_risk.roll_rate_matrix: 'period_length_months' must be a positive integer, got: " ~ period_length_months ~ "."
    ) }}
{%- endif -%}

{%- if minimum_cell_count is not number or minimum_cell_count < 1 or minimum_cell_count != minimum_cell_count | int -%}
    {{ exceptions.raise_compiler_error(
        "credit_risk.roll_rate_matrix: 'minimum_cell_count' must be an integer >= 1, got: " ~ minimum_cell_count ~ "."
    ) }}
{%- endif -%}

{%- for col in segment_cols -%}
    {%- if col in reserved_output_cols -%}
        {{ exceptions.raise_compiler_error(
            "credit_risk.roll_rate_matrix: segment_cols entry '" ~ col ~ "' collides with a reserved output column name."
        ) }}
    {%- endif -%}
{%- endfor -%}

with constants as (
    select
        {{ minimum_cell_count }} as minimum_cell_count,
        {{ period_length_months }} as period_length_months
),

duplicate_grain_pairs as (
    select {{ loan_id_col }}, {{ period_col }}, count(*) as row_count
    from {{ relation }}
    where {{ status_col }} = '{{ active_status_value }}'
    group by {{ loan_id_col }}, {{ period_col }}
    having count(*) > 1
),

grain_violation_count as (
    select count(*) as duplicate_pair_count
    from duplicate_grain_pairs
),

null_period_count as (
    select count(*) as null_count
    from {{ relation }}
    where {{ period_col }} is null
      and {{ status_col }} = '{{ active_status_value }}'
),

negative_balance_count as (
    select count(*) as negative_count
    from {{ relation }}
    where ({{ balance_col }} < 0 or {{ balance_col }} is null)
      and {{ status_col }} = '{{ active_status_value }}'
),

contract_assertions as (
    select
        1 / case when grain_violation_count.duplicate_pair_count > 0 then 0 else 1 end
            as _assert_grain,
        1 / case when null_period_count.null_count > 0 then 0 else 1 end
            as _assert_period_not_null,
        1 / case when negative_balance_count.negative_count > 0 then 0 else 1 end
            as _assert_balance_non_negative
    from grain_violation_count, null_period_count, negative_balance_count
),

active_periods as (
    select
        {{ loan_id_col }} as loan_id,
        cast({{ _date_trunc_month(period_col) }} as date) as period_date,
        {{ bucket_col }} as from_bucket,
        {{ balance_col }} as beginning_balance,
        {% for col in segment_cols %}{{ col }},
        {% endfor %}cast({{ _add_months(_date_trunc_month(period_col), period_length_months) }} as date) as next_period_date,
        contract_assertions._assert_grain as _assertion_pass
    from {{ relation }}
    cross join contract_assertions
    where {{ status_col }} = '{{ active_status_value }}'
),

at_risk_denominator as (
    select
        {% for col in segment_cols %}active_periods.{{ col }},
        {% endfor %}active_periods.period_date as observation_period,
        active_periods.from_bucket,
        count(distinct active_periods.loan_id) as at_risk_loan_count,
        sum(active_periods.beginning_balance) as at_risk_balance
    from active_periods
    inner join active_periods as next_period
        on active_periods.loan_id = next_period.loan_id
        and active_periods.next_period_date = next_period.period_date
    group by
        {% for col in segment_cols %}active_periods.{{ col }},
        {% endfor %}active_periods.period_date,
        active_periods.from_bucket
),

transition_events as (
    select
        {% for col in segment_cols %}current_period.{{ col }},
        {% endfor %}current_period.period_date as observation_period,
        current_period.from_bucket,
        next_period.from_bucket as to_bucket,
        current_period.loan_id,
        current_period.beginning_balance
    from active_periods as current_period
    inner join active_periods as next_period
        on current_period.loan_id = next_period.loan_id
        and current_period.next_period_date = next_period.period_date
    where current_period.from_bucket != next_period.from_bucket
),

non_self_transitions as (
    select
        {% for col in segment_cols %}transition_events.{{ col }},
        {% endfor %}transition_events.observation_period,
        transition_events.from_bucket,
        transition_events.to_bucket,
        count(distinct transition_events.loan_id) as transition_loan_count,
        sum(transition_events.beginning_balance) as transition_balance
    from transition_events
    group by
        {% for col in segment_cols %}transition_events.{{ col }},
        {% endfor %}transition_events.observation_period,
        transition_events.from_bucket,
        transition_events.to_bucket
),

non_self_aggregated as (
    select
        {% for col in segment_cols %}non_self_transitions.{{ col }},
        {% endfor %}non_self_transitions.observation_period,
        non_self_transitions.from_bucket,
        sum(non_self_transitions.transition_loan_count) as total_non_self_loan_count,
        sum(non_self_transitions.transition_balance) as total_non_self_balance
    from non_self_transitions
    group by
        {% for col in segment_cols %}non_self_transitions.{{ col }},
        {% endfor %}non_self_transitions.observation_period,
        non_self_transitions.from_bucket
),

self_transitions as (
    select
        {% for col in segment_cols %}at_risk_denominator.{{ col }},
        {% endfor %}at_risk_denominator.observation_period,
        at_risk_denominator.from_bucket,
        at_risk_denominator.from_bucket as to_bucket,
        at_risk_denominator.at_risk_loan_count - coalesce(
            non_self_aggregated.total_non_self_loan_count, 0
        ) as transition_loan_count,
        at_risk_denominator.at_risk_balance - coalesce(
            non_self_aggregated.total_non_self_balance, 0
        ) as transition_balance
    from at_risk_denominator
    left join non_self_aggregated
        on at_risk_denominator.observation_period = non_self_aggregated.observation_period
        and at_risk_denominator.from_bucket = non_self_aggregated.from_bucket
        {% for col in segment_cols %}
        and at_risk_denominator.{{ col }} = non_self_aggregated.{{ col }}
        {% endfor %}
),

all_observations as (
    select
        {% for col in segment_cols %}non_self_transitions.{{ col }},
        {% endfor %}non_self_transitions.observation_period,
        non_self_transitions.from_bucket,
        non_self_transitions.to_bucket,
        non_self_transitions.transition_loan_count,
        non_self_transitions.transition_balance,
        at_risk_denominator.at_risk_loan_count,
        at_risk_denominator.at_risk_balance
    from non_self_transitions
    inner join at_risk_denominator
        on non_self_transitions.observation_period = at_risk_denominator.observation_period
        and non_self_transitions.from_bucket = at_risk_denominator.from_bucket
        {% for col in segment_cols %}
        and non_self_transitions.{{ col }} = at_risk_denominator.{{ col }}
        {% endfor %}

    union all

    select
        {% for col in segment_cols %}self_transitions.{{ col }},
        {% endfor %}self_transitions.observation_period,
        self_transitions.from_bucket,
        self_transitions.to_bucket,
        self_transitions.transition_loan_count,
        self_transitions.transition_balance,
        at_risk_denominator.at_risk_loan_count,
        at_risk_denominator.at_risk_balance
    from self_transitions
    inner join at_risk_denominator
        on self_transitions.observation_period = at_risk_denominator.observation_period
        and self_transitions.from_bucket = at_risk_denominator.from_bucket
        {% for col in segment_cols %}
        and self_transitions.{{ col }} = at_risk_denominator.{{ col }}
        {% endfor %}
)

select
    {% for col in segment_cols %}all_observations.{{ col }},
    {% endfor %}all_observations.observation_period,
    constants.period_length_months,
    all_observations.from_bucket,
    all_observations.to_bucket,
    cast(all_observations.transition_loan_count as integer) as transition_loan_count,
    cast(all_observations.at_risk_loan_count as integer) as at_risk_loan_count,
    cast(all_observations.transition_balance as decimal(18, 2)) as transition_balance,
    cast(all_observations.at_risk_balance as decimal(18, 2)) as at_risk_balance,
    cast(
        cast(all_observations.transition_loan_count as double)
        / nullif(all_observations.at_risk_loan_count, 0)
        as decimal(10, 6)
    ) as transition_rate,
    cast(
        cast(all_observations.transition_balance as double)
        / nullif(all_observations.at_risk_balance, 0)
        as decimal(10, 6)
    ) as transition_balance_rate,
    all_observations.at_risk_loan_count < constants.minimum_cell_count as is_low_count_cell
from all_observations
cross join constants

{% endmacro %}
