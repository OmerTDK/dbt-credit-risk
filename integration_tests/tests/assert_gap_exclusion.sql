-- Gap-exclusion invariant: loan_c's Jan 2024 row is active (current) but its Feb 2024 row is
-- inactive, so loan_c must be excluded from the Jan at_risk_denominator.
-- Expected: at_risk_loan_count for Jan / current = 3 (loan_a, loan_b, loan_d), NOT 4.
-- If at_risk_denominator uses LEFT JOIN instead of INNER JOIN, loan_c is included and this
-- test returns 1 row (failure). With correct INNER JOIN it returns 0 rows (pass).
select
    observation_period,
    from_bucket,
    at_risk_loan_count
from {{ ref('roll_rate_output') }}
where observation_period = cast('2024-01-01' as date)
  and from_bucket = 'current'
  and at_risk_loan_count != 3
