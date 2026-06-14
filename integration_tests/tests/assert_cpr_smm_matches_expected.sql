with actual as (
    select
        origination_cohort,
        months_on_book,
        performing_pool_balance,
        prepaid_balance,
        eligible_loan_count,
        prepaying_loan_count,
        smm_rate,
        cpr_rate
    from {{ ref('cpr_smm_output') }}
),

expected as (
    select
        origination_cohort,
        months_on_book,
        cast(performing_pool_balance as decimal(18, 2)) as performing_pool_balance,
        cast(prepaid_balance as decimal(18, 2)) as prepaid_balance,
        eligible_loan_count,
        prepaying_loan_count,
        cast(smm_rate as decimal(10, 6)) as smm_rate,
        cast(cpr_rate as decimal(10, 6)) as cpr_rate
    from {{ ref('expected_cpr_smm') }}
),

mismatches as (
    select
        coalesce(actual.origination_cohort, expected.origination_cohort) as origination_cohort,
        coalesce(actual.months_on_book, expected.months_on_book) as months_on_book,
        case
            when actual.origination_cohort is null then 'missing_row_in_actual'
            when expected.origination_cohort is null then 'extra_row_in_actual'
            when abs(cast(actual.performing_pool_balance as double) - cast(expected.performing_pool_balance as double)) > 0.01 then 'performing_pool_balance_mismatch'
            when abs(cast(actual.prepaid_balance as double) - cast(expected.prepaid_balance as double)) > 0.01 then 'prepaid_balance_mismatch'
            when actual.eligible_loan_count != expected.eligible_loan_count then 'eligible_loan_count_mismatch'
            when actual.prepaying_loan_count != expected.prepaying_loan_count then 'prepaying_loan_count_mismatch'
            when abs(cast(actual.smm_rate as double) - cast(expected.smm_rate as double)) > 0.000001 then 'smm_rate_mismatch'
            when abs(cast(coalesce(actual.cpr_rate, 0) as double) - cast(coalesce(expected.cpr_rate, 0) as double)) > 0.000001 then 'cpr_rate_mismatch'
        end as failure_reason
    from actual
    full outer join expected
        on actual.origination_cohort = expected.origination_cohort
        and actual.months_on_book = expected.months_on_book
    where
        actual.origination_cohort is null
        or expected.origination_cohort is null
        or abs(cast(actual.performing_pool_balance as double) - cast(expected.performing_pool_balance as double)) > 0.01
        or abs(cast(actual.prepaid_balance as double) - cast(expected.prepaid_balance as double)) > 0.01
        or actual.eligible_loan_count != expected.eligible_loan_count
        or actual.prepaying_loan_count != expected.prepaying_loan_count
        or abs(cast(actual.smm_rate as double) - cast(expected.smm_rate as double)) > 0.000001
        or abs(cast(coalesce(actual.cpr_rate, 0) as double) - cast(coalesce(expected.cpr_rate, 0) as double)) > 0.000001
)

select
    origination_cohort,
    months_on_book,
    failure_reason
from mismatches
