"""Integration tests for the vintage_curve macro.

Runs the full dbt integration-test project against DuckDB in-memory and
asserts that the macro output matches the hand-verified expected seed row
for row.
"""

import os
import subprocess
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
INTEGRATION_TESTS_DIR = REPO_ROOT / "integration_tests"
DBT_BIN = REPO_ROOT / ".venv" / "bin" / "dbt"
DBT_PROFILES_FLAG = ["--profiles-dir", "."]


def _dbt(args: list[str]) -> subprocess.CompletedProcess:
    """Run a dbt command inside integration_tests/ and return the result."""
    return subprocess.run(
        [str(DBT_BIN), *args, *DBT_PROFILES_FLAG],
        cwd=INTEGRATION_TESTS_DIR,
        env={**os.environ},
        capture_output=True,
        text=True,
        check=False,
    )


def test_vintage_curve_macro_exists() -> None:
    """The vintage_curve macro must be resolvable by dbt parse."""
    macro_file = REPO_ROOT / "macros" / "vintage_curve.sql"
    assert macro_file.exists(), (
        f"macro file not found: {macro_file}. "
        "Implement macros/vintage_curve.sql before tests will pass."
    )


def test_vintage_curve_build_succeeds() -> None:
    result = _dbt(["build", "--select", "vintage_curve_output+"])
    assert result.returncode == 0, (
        f"dbt build of vintage_curve_output failed (exit {result.returncode}):\n"
        f"stdout:\n{result.stdout}\n"
        f"stderr:\n{result.stderr}"
    )
