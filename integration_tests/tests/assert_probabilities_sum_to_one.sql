with constants as (
    select 0.001 as tolerance
),

period_bucket_sums as (
    select
        observation_period,
        from_bucket,
        sum(transition_loan_count) as total_transition_count,
        max(at_risk_loan_count) as expected_at_risk_count
    from {{ ref('roll_rate_output') }}
    group by
        observation_period,
        from_bucket
)

select
    period_bucket_sums.observation_period,
    period_bucket_sums.from_bucket,
    period_bucket_sums.total_transition_count,
    period_bucket_sums.expected_at_risk_count
from period_bucket_sums
cross join constants
where abs(
    cast(period_bucket_sums.total_transition_count as double)
    - cast(period_bucket_sums.expected_at_risk_count as double)
) > constants.tolerance
