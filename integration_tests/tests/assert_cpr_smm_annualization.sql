-- Invariant: CPR = 1 - (1 - SMM)^12 for all rows where performing_pool_balance > 0.
-- A mismatch means the cpr_rate formula was mis-implemented.
with constants as (
    select
        12 as months_per_year,
        0.000001 as tolerance
),

computed as (
    select
        origination_cohort,
        months_on_book,
        smm_rate,
        cpr_rate,
        cast(
            1.0 - power(1.0 - cast(smm_rate as double), constants.months_per_year)
            as decimal(10, 6)
        ) as expected_cpr_rate
    from {{ ref('cpr_smm_output') }}
    cross join constants
    where performing_pool_balance > 0
)

select
    origination_cohort,
    months_on_book,
    smm_rate,
    cpr_rate,
    expected_cpr_rate
from computed
cross join constants
where abs(cast(cpr_rate as double) - cast(expected_cpr_rate as double)) > constants.tolerance
