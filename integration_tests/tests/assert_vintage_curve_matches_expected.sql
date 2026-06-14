with actual as (
    select
        origination_cohort,
        months_on_book,
        cohort_loan_count,
        cohort_principal,
        cumulative_default_count,
        cumulative_prepayment_count,
        surviving_non_defaulted_count,
        loans_at_risk_count,
        cumulative_default_rate,
        cumulative_prepayment_rate,
        is_censored
    from {{ ref('vintage_curve_output') }}
),

expected as (
    select
        origination_cohort,
        months_on_book,
        cohort_loan_count,
        cast(cohort_principal as decimal(18, 2)) as cohort_principal,
        cumulative_default_count,
        cumulative_prepayment_count,
        surviving_non_defaulted_count,
        loans_at_risk_count,
        cast(cumulative_default_rate as decimal(10, 6)) as cumulative_default_rate,
        cast(cumulative_prepayment_rate as decimal(10, 6)) as cumulative_prepayment_rate,
        is_censored
    from {{ ref('expected_vintage_curve') }}
),

mismatches as (
    select
        coalesce(actual.origination_cohort, expected.origination_cohort) as origination_cohort,
        coalesce(actual.months_on_book, expected.months_on_book) as months_on_book,
        case
            when actual.origination_cohort is null then 'missing_row_in_actual'
            when expected.origination_cohort is null then 'extra_row_in_actual'
            when actual.cohort_loan_count != expected.cohort_loan_count then 'cohort_loan_count_mismatch'
            when abs(cast(actual.cohort_principal as double) - cast(expected.cohort_principal as double)) > 0.01 then 'cohort_principal_mismatch'
            when actual.cumulative_default_count != expected.cumulative_default_count then 'cumulative_default_count_mismatch'
            when actual.cumulative_prepayment_count != expected.cumulative_prepayment_count then 'cumulative_prepayment_count_mismatch'
            when actual.surviving_non_defaulted_count != expected.surviving_non_defaulted_count then 'surviving_non_defaulted_count_mismatch'
            when actual.loans_at_risk_count != expected.loans_at_risk_count then 'loans_at_risk_count_mismatch'
            when abs(cast(actual.cumulative_default_rate as double) - cast(expected.cumulative_default_rate as double)) > 0.000001 then 'cumulative_default_rate_mismatch'
            when abs(cast(actual.cumulative_prepayment_rate as double) - cast(expected.cumulative_prepayment_rate as double)) > 0.000001 then 'cumulative_prepayment_rate_mismatch'
            when actual.is_censored != expected.is_censored then 'is_censored_mismatch'
        end as failure_reason
    from actual
    full outer join expected
        on actual.origination_cohort = expected.origination_cohort
        and actual.months_on_book = expected.months_on_book
    where
        actual.origination_cohort is null
        or expected.origination_cohort is null
        or actual.cohort_loan_count != expected.cohort_loan_count
        or abs(cast(actual.cohort_principal as double) - cast(expected.cohort_principal as double)) > 0.01
        or actual.cumulative_default_count != expected.cumulative_default_count
        or actual.cumulative_prepayment_count != expected.cumulative_prepayment_count
        or actual.surviving_non_defaulted_count != expected.surviving_non_defaulted_count
        or actual.loans_at_risk_count != expected.loans_at_risk_count
        or abs(cast(actual.cumulative_default_rate as double) - cast(expected.cumulative_default_rate as double)) > 0.000001
        or abs(cast(actual.cumulative_prepayment_rate as double) - cast(expected.cumulative_prepayment_rate as double)) > 0.000001
        or actual.is_censored != expected.is_censored
)

select
    origination_cohort,
    months_on_book,
    failure_reason
from mismatches
