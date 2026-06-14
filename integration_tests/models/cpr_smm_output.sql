{{ cpr_smm(
    relation=ref('loan_performance_cpr'),
    loan_id_col='loan_id',
    origination_date_col='origination_date',
    performance_date_col='performance_date',
    beginning_balance_col='beginning_balance',
    prepaid_amount_col='prepaid_amount',
    is_active_col='is_active',
    is_prepayment_col='is_prepayment',
    cohort_granularity='quarter'
) }}
