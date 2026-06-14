-- Regression guard: inactive prepaying loans must be excluded from prepaid_balance
-- and prepaying_loan_count. The fixture (loan_performance_cpr_inactive) has exactly
-- one active prepaying loan (loan_ia2, prepaid_amount=8000) and one INACTIVE prepaying
-- loan (loan_ia3, prepaid_amount=5000) in the same cohort-MOB. Under the pre-fix
-- implementation, loan_ia3 leaked into both metrics; this test would have returned two
-- rows (one per violated column) and FAILED. After the fix, no rows are returned.
with actual as (
    select
        origination_cohort,
        months_on_book,
        prepaid_balance,
        prepaying_loan_count
    from {{ ref('cpr_smm_inactive_output') }}
),

violations as (
    select
        origination_cohort,
        months_on_book,
        prepaid_balance,
        prepaying_loan_count,
        case
            when abs(cast(prepaid_balance as double) - 8000.0) > 0.01
                then 'prepaid_balance_includes_inactive_loan: expected 8000.00 got ' || cast(prepaid_balance as varchar)
            when prepaying_loan_count != 1
                then 'prepaying_loan_count_includes_inactive_loan: expected 1 got ' || cast(prepaying_loan_count as varchar)
        end as failure_reason
    from actual
    where
        abs(cast(prepaid_balance as double) - 8000.0) > 0.01
        or prepaying_loan_count != 1
)

select
    origination_cohort,
    months_on_book,
    prepaid_balance,
    prepaying_loan_count,
    failure_reason
from violations
