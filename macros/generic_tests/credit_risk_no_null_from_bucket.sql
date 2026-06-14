{% test credit_risk_no_null_from_bucket(model) %}

select
    observation_period,
    from_bucket,
    to_bucket
from {{ model }}
where from_bucket is null

{% endtest %}
