-- Structural invariants: loans_at_risk_count must never be negative,
-- and cumulative_default_rate must be monotonically non-decreasing across MOBs.
-- These catch correlated bugs that the tautological identity (X != X) cannot detect.
with base as (
    select
        origination_cohort,
        months_on_book,
        loans_at_risk_count,
        cumulative_default_count,
        cohort_loan_count,
        cumulative_default_rate,
        lag(cumulative_default_rate) over (
            partition by origination_cohort
            order by months_on_book
        ) as prev_cumulative_default_rate
    from {{ ref('vintage_curve_output') }}
)

select
    origination_cohort,
    months_on_book,
    loans_at_risk_count,
    cumulative_default_rate,
    prev_cumulative_default_rate,
    case
        when loans_at_risk_count < 0 then 'loans_at_risk_negative'
        when loans_at_risk_count > cohort_loan_count then 'loans_at_risk_exceeds_cohort'
        when cumulative_default_rate < coalesce(prev_cumulative_default_rate, 0)
            then 'cumulative_default_rate_not_monotonic'
    end as failure_reason
from base
where
    loans_at_risk_count < 0
    or loans_at_risk_count > cohort_loan_count
    or cumulative_default_rate < coalesce(prev_cumulative_default_rate, 0)
