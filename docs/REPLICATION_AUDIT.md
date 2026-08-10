# ExpertGold1 Replication Audit

Status: **pre-code audit, updated after four unique follow-up videos**

## Audit conclusion

A 100% copy of the videos' hidden decision process and profitability is not
technically verifiable. The original highlight plus five follow-up links provide
five unique clips because two follow-up links resolve to the same video. The
footage does not contain complete entry rules, complete trade history, losing
sessions, broker execution, or raw ticks. Key sections are edited or begin after
the positions are already open.

The frame-level source map and account-risk observations are recorded in
`VIDEO_EVIDENCE_MATRIX.md`.

We can target:

1. **100% specification fidelity** — code follows every approved deterministic
   rule in `FINAL_BEHAVIOR_SPEC.md`.
2. **Observable behavior fidelity** — same-side impulse entries, capital-capped
   stacking, and whole-basket profit close.
3. **Measured profitability** — accepted only after out-of-sample tick replay and
   Deriv demo forward testing.

We must not claim 100% profit fidelity or guaranteed “sureball” entries.

## What the videos establish

| Evidence | Confidence |
| --- | --- |
| XAUUSDm shown on MT5 mobile using M1/M5/M15 views | High |
| Entry class is price-movement / impulse mash on a naked chart | High |
| No classic indicator panels visible across the four unique clips | High |
| Many clustered same-direction entries using repeated fixed lots per basket | High |
| Both BUY and SELL baskets appear | High |
| Bulk Operations menu is used | High |
| Momentum continuation appears in at least one bearish move | High |
| Baskets also appear around post-spike reversals | Medium; exact trigger is off-screen |
| Direction can flip between adjacent baskets | High |
| Positions can remain open through severe adverse movement | High |
| Negative free margin and near-stop-out margin levels occur | High |
| Immediate close at first positive P/L | Contradicted |
| Trading every micro-spike | Not established |
| Exact numeric threshold for every mash | Unknown |
| Stop-loss and daily-loss policy | Unknown |
| Whether entries are momentum, fade, or both | Partly inferred |
| Long-term expectancy/profitability | Unknown |

**Entry trigger (user + video alignment):** the trader enters on **price
movement**, not on a disclosed indicator formula. That class is locked. Exact
tick cutoffs remain unknown, so Phase 1 uses the deterministic tick-window +
direction-score rules in `FINAL_BEHAVIOR_SPEC.md`.

The follow-up clips strengthen the evidence for the execution style—rapid entry
bursts, one-sided baskets, direction flips, and bulk closes. They also weaken the
claim that this is safe micro-scalping: the recordings show selected large M15
moves, large profit givebacks, negative free margin, and margin levels as low as
approximately 29–34%.

## Missing evidence required for a closer clone

- Unedited recordings showing chart, order taps, and trade list together.
- Exact broker/server, symbol specifications, leverage, and account type.
- Exported MT5 account history including every loss and deposit/withdrawal.
- Entry and exit timestamps with millisecond precision.
- Raw Deriv tick data and spread at those timestamps.
- Exact lot progression, stop policy, news/session policy, and manual overrides.
- At least several weeks of ordinary sessions, not only winning highlights.
- A continuous recording that starts before the first order and shows every
  order tap, modification, close, and resulting history without cuts.

Without these, any claimed exact “instinct clone” would be invented.

## Engines that must exist

### 1. Symbol Capability Engine

- Discover volume min/step/max, tick size/value, stops level, trade mode, and
  margin requirements.
- Normalize Gold and Wall Street 30 separately.
- Reject trading when contract data is invalid or minimum volume is unaffordable.

### 2. Tick Window Engine

- Ring buffer of real ticks with 1s/3s/10s views.
- Detect stale/duplicate/out-of-order ticks.
- Calculate displacement, path length, velocity, acceleration, persistence, and
  directional efficiency.

### 3. Cost and Execution Engine

- Adaptive spread baseline per symbol/session.
- Require impulse travel to exceed expected round-trip cost.
- Record requested price, fill price, slippage, latency, reject/partial-close
  results, and realized costs.

### 4. Regime Engine

- Classify `CHOP`, `CONTINUATION`, `EXHAUSTION`, `SPREAD_SHOCK`, and `LOCKOUT`.
- Phase 1 trades `CONTINUATION` only.
- `EXHAUSTION`/fade remains disabled until separately validated.

### 5. Direction Confidence Engine

- Deterministic 0–100 score from velocity, displacement/cost ratio, efficiency,
  micro-break, persistence, and M1/M5 context.
- Entry at ≥75; optional add at ≥80.
- Emit a reason trace for every accepted and rejected signal.

### 6. Capital and Risk Engine

- Compute real stop-risk using tick value and emergency stop distance.
- Below $20 equity: one default layer.
- Skip when minimum lot exceeds the basket risk ceiling.
- Basket loss, daily loss, consecutive-loss, margin, and execution-quality
  lockouts are mandatory.

### 7. Basket Engine

- One direction per symbol/magic.
- Add only after favorable progression; never average a loser.
- Close the whole EA basket on net profit, loss, opposite impulse, timeout, or
  emergency—not only profitable tickets.

### 8. Cooldown and Anti-Churn Engine

- Assign a movement ID.
- One movement cannot repeatedly reopen after a small oscillation.
- Re-arm only after velocity/price resets or a genuinely new impulse forms.

### 9. Telemetry and Replay Engine

- Persist signal features, confidence score, state transitions, risk decision,
  orders, fills, exits, and costs.
- Replay recorded ticks deterministically.
- Compare expected and actual decisions before changing parameters.

## Do not add before evidence

- Martingale, recovery grid, unlimited layering, or adding to losses.
- Fixed 1.00 lot or forced broker-minimum lot on a $10 account.
- Level 2/DOM as a required Gold/US30 CFD signal.
- Machine learning marketed as “instinct” without a labeled dataset.
- Automatic parameter optimization against one historical period.
- Post-news spike chasing while spread/slippage gates are violated.
- Closing only winners and leaving losing positions behind.
- Any claim of guaranteed profitability or 100% win rate.
- Copying the videos' negative-free-margin or near-stop-out behavior.
- Treating a displayed balance jump as verified live-account performance.

## Pre-code acceptance gate

Coding can start only when all are true:

- [x] Observable video behaviors are separated from assumptions.
- [x] Phase 1 scope is continuation-only.
- [x] State machine, score, stacking, exits, and cooldown are specified.
- [x] $10 affordability can veto every entry.
- [x] Gold and Wall Street 30 use symbol-normalized values.
- [x] Required telemetry and replay behavior are specified.
- [ ] User approves specification fidelity instead of guaranteed profit fidelity.
- [ ] Review choice (`bugbot` or `security`) is supplied and completed.

## Validation plan after implementation

1. Unit-test formulas and state transitions with synthetic ticks.
2. Replay clean impulse, chop, failed break, spread shock, reversal, and missing
   tick scenarios.
3. Run MT5 Strategy Tester using real ticks where available.
4. Keep parameters fixed for an out-of-sample period.
5. Forward-test separately on Deriv Gold and Wall Street 30 demo.
6. Reject the release if net expectancy after costs is not positive or risk
   invariants are violated.
