{{ roll_rate_matrix(
    relation=ref('loan_performance_segmented'),
    loan_id_col='loan_id',
    period_col='period_date',
    bucket_col='delinquency_bucket',
    balance_col='outstanding_balance',
    status_col='loan_status',
    active_status_value='active',
    segment_cols=['product_type'],
    period_length_months=1,
    minimum_cell_count=10
) }}
