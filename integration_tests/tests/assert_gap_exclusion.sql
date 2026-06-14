select
    observation_period,
    from_bucket,
    to_bucket,
    transition_loan_count
from {{ ref('roll_rate_output') }}
where observation_period = cast('2024-01-01' as date)
  and from_bucket = 'current'
  and to_bucket = 'dpd_30'
  and transition_loan_count > 1
