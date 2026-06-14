{% test credit_risk_no_negative_self_transition(model) %}

select
    observation_period,
    from_bucket,
    to_bucket,
    transition_loan_count
from {{ model }}
where from_bucket = to_bucket
  and transition_loan_count < 0

{% endtest %}
