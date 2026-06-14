{{ vintage_curve(
    relation=ref('loan_performance_vintage'),
    loan_id_col='loan_id',
    origination_date_col='origination_date',
    performance_date_col='performance_date',
    is_default_col='is_default',
    is_prepayment_col='is_prepayment',
    balance_col='beginning_balance',
    cohort_granularity='quarter',
    censored_threshold=10
) }}
