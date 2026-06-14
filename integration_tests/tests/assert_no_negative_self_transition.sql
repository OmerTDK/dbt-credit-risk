select
    observation_period,
    from_bucket,
    to_bucket,
    transition_loan_count
from {{ ref('roll_rate_output') }}
where from_bucket = to_bucket
  and transition_loan_count < 0
