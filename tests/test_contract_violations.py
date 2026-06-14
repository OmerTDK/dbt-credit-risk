"""Compile-time validation tests for the roll_rate_matrix macro.

Verifies that missing or malformed arguments raise CompilationErrors at
dbt parse time — before any warehouse round-trip.
"""

import os
import subprocess
import textwrap
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
INTEGRATION_TESTS_DIR = REPO_ROOT / "integration_tests"
DBT_BIN = REPO_ROOT / ".venv" / "bin" / "dbt"


def _run_dbt_parse(extra_model_sql: str) -> subprocess.CompletedProcess:
    """Write a temporary model with the given SQL body, run dbt parse, return result."""
    model_path = INTEGRATION_TESTS_DIR / "models" / "_tmp_violation_probe.sql"
    model_path.write_text(extra_model_sql)
    try:
        return subprocess.run(
            [str(DBT_BIN), "parse", "--no-partial-parse", "--profiles-dir", "."],
            cwd=INTEGRATION_TESTS_DIR,
            env={**os.environ},
            capture_output=True,
            text=True,
            check=False,
        )
    finally:
        model_path.unlink(missing_ok=True)


def test_missing_relation_raises_compilation_error() -> None:
    sql = textwrap.dedent("""\
        {{ roll_rate_matrix(
            relation=none,
            loan_id_col='loan_id',
            period_col='period_date',
            bucket_col='delinquency_bucket',
            balance_col='outstanding_balance',
            status_col='loan_status',
            active_status_value='active'
        ) }}
    """)
    result = _run_dbt_parse(sql)
    assert result.returncode != 0, "Expected dbt parse to fail on missing relation"
    assert "relation" in result.stdout + result.stderr


def test_segment_cols_as_string_raises_compilation_error() -> None:
    sql = textwrap.dedent("""\
        {{ roll_rate_matrix(
            relation=ref('loan_performance'),
            loan_id_col='loan_id',
            period_col='period_date',
            bucket_col='delinquency_bucket',
            balance_col='outstanding_balance',
            status_col='loan_status',
            active_status_value='active',
            segment_cols='product_type'
        ) }}
    """)
    result = _run_dbt_parse(sql)
    assert result.returncode != 0, "Expected dbt parse to fail on segment_cols as string"
    combined = result.stdout + result.stderr
    assert "segment_cols" in combined
    assert "list" in combined.lower() or "Did you mean" in combined


def test_zero_period_length_raises_compilation_error() -> None:
    sql = textwrap.dedent("""\
        {{ roll_rate_matrix(
            relation=ref('loan_performance'),
            loan_id_col='loan_id',
            period_col='period_date',
            bucket_col='delinquency_bucket',
            balance_col='outstanding_balance',
            status_col='loan_status',
            active_status_value='active',
            period_length_months=0
        ) }}
    """)
    result = _run_dbt_parse(sql)
    assert result.returncode != 0, "Expected dbt parse to fail on period_length_months=0"
    combined = result.stdout + result.stderr
    assert "period_length_months" in combined


def test_vintage_curve_missing_relation_raises_error() -> None:
    sql = textwrap.dedent("""\
        {{ vintage_curve(
            relation=none,
            loan_id_col='loan_id',
            origination_date_col='origination_date',
            performance_date_col='performance_date',
            is_default_col='is_default',
            is_prepayment_col='is_prepayment',
            balance_col='beginning_balance'
        ) }}
    """)
    result = _run_dbt_parse(sql)
    assert result.returncode != 0, "Expected dbt parse to fail on missing relation"
    assert "relation" in result.stdout + result.stderr


def test_vintage_curve_invalid_cohort_granularity_raises_error() -> None:
    sql = textwrap.dedent("""\
        {{ vintage_curve(
            relation=ref('loan_performance_vintage'),
            loan_id_col='loan_id',
            origination_date_col='origination_date',
            performance_date_col='performance_date',
            is_default_col='is_default',
            is_prepayment_col='is_prepayment',
            balance_col='beginning_balance',
            cohort_granularity='year'
        ) }}
    """)
    result = _run_dbt_parse(sql)
    assert result.returncode != 0, "Expected dbt parse to fail on invalid cohort_granularity"
    combined = result.stdout + result.stderr
    assert "cohort_granularity" in combined


def test_cpr_smm_missing_relation_raises_error() -> None:
    sql = textwrap.dedent("""\
        {{ cpr_smm(
            relation=none,
            loan_id_col='loan_id',
            origination_date_col='origination_date',
            performance_date_col='performance_date',
            beginning_balance_col='beginning_balance',
            prepaid_amount_col='prepaid_amount',
            is_active_col='is_active',
            is_prepayment_col='is_prepayment'
        ) }}
    """)
    result = _run_dbt_parse(sql)
    assert result.returncode != 0, "Expected dbt parse to fail on missing relation"
    assert "relation" in result.stdout + result.stderr


def test_cpr_smm_invalid_cohort_granularity_raises_error() -> None:
    sql = textwrap.dedent("""\
        {{ cpr_smm(
            relation=ref('loan_performance_cpr'),
            loan_id_col='loan_id',
            origination_date_col='origination_date',
            performance_date_col='performance_date',
            beginning_balance_col='beginning_balance',
            prepaid_amount_col='prepaid_amount',
            is_active_col='is_active',
            is_prepayment_col='is_prepayment',
            cohort_granularity='week'
        ) }}
    """)
    result = _run_dbt_parse(sql)
    assert result.returncode != 0, "Expected dbt parse to fail on invalid cohort_granularity"
    combined = result.stdout + result.stderr
    assert "cohort_granularity" in combined
