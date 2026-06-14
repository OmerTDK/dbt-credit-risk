-- Invariant: loans_at_risk_count = cohort_loan_count - cumulative_default_count - cumulative_prepayment_count
-- This is the fundamental balance identity of the vintage curve: every loan is either
-- defaulted, prepaid (non-defaulted), or still at risk. Violations indicate a logic error.
select
    origination_cohort,
    months_on_book,
    loans_at_risk_count,
    cohort_loan_count - cumulative_default_count - cumulative_prepayment_count as expected_at_risk_count
from {{ ref('vintage_curve_output') }}
where
    loans_at_risk_count
    != cohort_loan_count - cumulative_default_count - cumulative_prepayment_count
