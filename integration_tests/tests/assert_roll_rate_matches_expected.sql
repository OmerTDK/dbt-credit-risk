with actual as (
    select
        observation_period,
        from_bucket,
        to_bucket,
        transition_loan_count,
        at_risk_loan_count,
        transition_balance,
        at_risk_balance,
        transition_rate,
        transition_balance_rate,
        is_low_count_cell
    from {{ ref('roll_rate_output') }}
),

expected as (
    select
        observation_period,
        from_bucket,
        to_bucket,
        transition_loan_count,
        at_risk_loan_count,
        cast(transition_balance as decimal(18, 2)) as transition_balance,
        cast(at_risk_balance as decimal(18, 2)) as at_risk_balance,
        cast(transition_rate as decimal(10, 6)) as transition_rate,
        cast(transition_balance_rate as decimal(10, 6)) as transition_balance_rate,
        is_low_count_cell
    from {{ ref('expected_roll_rate_matrix') }}
),

mismatches as (
    select
        coalesce(actual.observation_period, expected.observation_period) as observation_period,
        coalesce(actual.from_bucket, expected.from_bucket) as from_bucket,
        coalesce(actual.to_bucket, expected.to_bucket) as to_bucket,
        case
            when actual.observation_period is null then 'missing_row_in_actual'
            when expected.observation_period is null then 'extra_row_in_actual'
            when actual.transition_loan_count != expected.transition_loan_count then 'transition_loan_count_mismatch'
            when actual.at_risk_loan_count != expected.at_risk_loan_count then 'at_risk_loan_count_mismatch'
            when abs(cast(actual.transition_rate as double) - cast(expected.transition_rate as double)) > 0.000001 then 'transition_rate_mismatch'
            when abs(cast(actual.transition_balance_rate as double) - cast(expected.transition_balance_rate as double)) > 0.000001 then 'transition_balance_rate_mismatch'
            when actual.is_low_count_cell != expected.is_low_count_cell then 'is_low_count_cell_mismatch'
            when abs(cast(actual.transition_balance as double) - cast(expected.transition_balance as double)) > 0.01 then 'transition_balance_mismatch'
            when abs(cast(actual.at_risk_balance as double) - cast(expected.at_risk_balance as double)) > 0.01 then 'at_risk_balance_mismatch'
        end as failure_reason
    from actual
    full outer join expected
        on actual.observation_period = expected.observation_period
        and actual.from_bucket = expected.from_bucket
        and actual.to_bucket = expected.to_bucket
    where
        actual.observation_period is null
        or expected.observation_period is null
        or actual.transition_loan_count != expected.transition_loan_count
        or actual.at_risk_loan_count != expected.at_risk_loan_count
        or abs(cast(actual.transition_rate as double) - cast(expected.transition_rate as double)) > 0.000001
        or abs(cast(actual.transition_balance_rate as double) - cast(expected.transition_balance_rate as double)) > 0.000001
        or actual.is_low_count_cell != expected.is_low_count_cell
        or abs(cast(actual.transition_balance as double) - cast(expected.transition_balance as double)) > 0.01
        or abs(cast(actual.at_risk_balance as double) - cast(expected.at_risk_balance as double)) > 0.01
)

select
    observation_period,
    from_bucket,
    to_bucket,
    failure_reason
from mismatches
