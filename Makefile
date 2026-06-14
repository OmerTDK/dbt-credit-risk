.DEFAULT_GOAL := help

.PHONY: help install lint test dbt-parse dbt-build ci docker-build docker-test

help: ## List available targets
	@grep -E '^[a-zA-Z][a-zA-Z0-9_-]*:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "%-16s %s\n", $$1, $$2}'

install: ## Install dependencies into .venv
	uv sync

lint: ## Ruff lint and format check, plus SQLFluff lint on SQL macros
	uv run ruff check .
	uv run ruff format --check .
	uv run sqlfluff lint macros/

test: ## Run the test suite (includes integration dbt build via subprocess)
	uv run pytest -v

dbt-parse: ## Parse the integration test project
	cd integration_tests && ../.venv/bin/dbt parse --profiles-dir .

dbt-build: ## Build and test the integration dbt project
	cd integration_tests && ../.venv/bin/dbt build --profiles-dir .

ci: lint test ## Run the full CI suite locally

docker-build: ## Build the project image
	docker build -t dbt-credit-risk .

docker-test: ## Run the test suite inside the image
	docker run --rm dbt-credit-risk
