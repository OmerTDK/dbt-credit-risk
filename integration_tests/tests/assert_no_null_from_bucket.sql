select
    observation_period,
    from_bucket,
    to_bucket
from {{ ref('roll_rate_output') }}
where from_bucket is null
