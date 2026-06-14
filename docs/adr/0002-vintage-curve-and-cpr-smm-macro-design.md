# ADR-0002: Vintage-Curve and CPR/SMM Macro Design

**Date:** 2026-06-14
**Status:** Accepted

## Context

Phase 2 adds two macro families to the package: `vintage_curve` and `cpr_smm`.
Both are extracted and generalized from a source credit analytics platform's risk
marts. The design decisions below are independent of Phase 1's roll-rate decisions
but follow the same three-layer validation pattern.

Three concrete choices required non-obvious tradeoffs:

1. **How to compute origination cohort principal** — which row's balance represents
   the loan's origination exposure
2. **How to extend event flags beyond a loan's observed data window** — a loan that
   defaults at MOB 2 and has no later rows must still count as defaulted at MOB 3+
3. **CPR/SMM denominator: performing-pool-only vs. total pool**

## Decision

### 1. Origination balance = first performance period's beginning balance

The `vintage_curve` macro computes `cohort_principal` as the sum of each loan's
beginning balance at its earliest observed performance date — derived via a
`MIN(performance_date)` join per loan, not `MIN(beginning_balance)`.

### 2. All loans contribute to every cohort MOB up to the cohort max

In `loan_milestone_flags`, each loan joins the cohort's `mob_spine` without filtering
on the loan's own `total_mob`. A loan that defaults at MOB 2 and ceases reporting
contributes `has_defaulted_by_mob = 1` at MOBs 3, 4, 5, … 6 (the cohort's maximum).
Without this, the cumulative default rate drops to zero after MOB 2 — the exact
opposite of a correct vintage curve.

### 3. CPR/SMM denominator = performing-pool-only (non-prepaying active loans)

The `cpr_smm` macro follows the reference implementation:

- `performing_pool_balance` = sum of `beginning_balance` where `is_active AND NOT is_prepayment`
- `prepaid_balance` = sum of `prepaid_amount` where `is_prepayment`
- `SMM = prepaid_balance / performing_pool_balance`

The denominator is the pool that did NOT prepay this month — the conditional pool.
This contrasts with the total-pool SMM definition used in some textbooks
(`SMM = prepaid / (performing + prepaid)`). Callers who want total-pool SMM must
pass a pre-computed denominator or transform the output.

`CPR = 1 - (1 - SMM)^12`. When `performing_pool_balance = 0`, `cpr_rate` is NULL
(not 0) to avoid implying a 0% CPR from a division-by-zero that is actually undefined.

## Alternatives considered

### A. Use the minimum observed balance as origination principal

`MIN(beginning_balance)` per loan picks the amortized (lower) balance rather than
the origination balance. For loan_b in our seed: `MIN()` = 14,000 (defaulted-month
balance) vs. first-period = 15,000. Using the minimum silently understates the
cohort's origination exposure. Rejected.

### B. Filter `loan_milestone_flags` on `loan.total_mob`

Filtering `mob_spine.months_on_book <= loan_summary.total_mob` appears natural:
"only count a loan for MOBs where it has data." But for defaulted loans that stop
reporting after default, this zeroes out their contribution to post-default cumulative
counts. A loan that defaulted at MOB 2 out of a 6-MOB cohort would contribute 0 to
cumulative_default_count at MOBs 3-6, producing a vintage curve that curves back down
— which is not what a vintage curve represents. The correct semantics are: once
an event (default or prepayment) occurs, it is permanent; the flag propagates to all
future MOBs in the cohort regardless of whether the loan has subsequent rows. Rejected.

### C. Total-pool SMM denominator

`SMM_total = prepaid / (performing + prepaid)` is the ABS (Asset-Backed Securities)
convention used in US agency MBS prepayment reports. The conditional-pool convention
(`SMM_conditional = prepaid / performing`) is common in European consumer-lending
analytics and was the convention in the source flagship. Using the ABS convention
would require re-labeling the columns and documenting the change prominently; callers
familiar with the conditional-pool convention would get different numbers for the same
input. Rejected in favour of matching the source convention.

## Consequences

**Easier:**
- The integration test seed demonstrates both the origination-balance bug (row ordering
  matters — MIN is wrong) and the mob-propagation bug (loan_b's default count at MOB 3+).
  Both are caught by `assert_vintage_curve_matches_expected`.
- The CPR annualization identity `CPR = 1-(1-SMM)^12` is independently verified by
  `assert_cpr_smm_annualization` — a mutation of the formula in the macro would produce
  a divergent CPR and fail this test without touching the expected seed.
- `cohort_granularity='month'|'quarter'` is shared between both macros via the same
  `_date_trunc_month` / `_date_trunc_quarter` helper macros. The integer range
  generation in `vintage_curve`'s mob spine is handled by the `_generate_series`
  helper, keeping adapter-specific branching in exactly three well-isolated places.

**Harder:**
- The `first_period_per_loan` + `loan_origination_info` join pattern adds two CTEs to
  `vintage_curve` that would not be needed if DuckDB/BigQuery shared a `FIRST_VALUE()`
  aggregate (not a window function). The join on `MIN(performance_date)` is a portable
  alternative but less readable than `FIRST(balance ORDER BY period)`.
- The conditional-pool SMM denominator must be documented explicitly in the macro's
  input contract; callers coming from total-pool conventions will get higher SMM values
  for the same loan portfolio. This will be documented in `docs/macros/` (Phase 3).

**Committed to:**
- Output schema for both macros is the public contract. Additive columns can be
  introduced in minor versions; removing or renaming existing columns requires a major
  version bump.
- `cohort_granularity` defaults to `'quarter'` for both macros, matching the source
  platform's default. Callers who want monthly cohorts must pass `cohort_granularity='month'`
  explicitly.
