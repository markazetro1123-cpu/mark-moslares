# Limitless Micro-Impulse Scalper — Final Behavior Specification

Status: **behavior frozen for Phase 1; no EA code yet**

## 1. Evidence boundary

Multi-video ExpertGold1 evidence (`docs/VIDEO_EVIDENCE_MATRIX.md`) proves the
trader:

- watches `XAUUSDm` on MT5 mobile (M1/M5/M15 views; M15 common in highlights);
- enters by **price-movement / impulse mash** on a naked chart (no classic
  indicators);
- opens many same-direction fixed-lot positions in tight clusters (1.00 / 1.60 /
  2.00 lots appear across clips);
- flips direction between baskets as price regime changes;
- uses MT5 Bulk Operations (Close Profitable / Close All) for exits; and
- also experiences severe floating drawdown and negative free margin.

It does **not** reveal a complete mathematical entry formula or prove that every
micro-spike is profitably tradable. Our EA copies the observable behavior class
(qualified price-movement stack + basket bulk close) with $10-safe money
management—not TikTok lot spam or an unknowable “instinct.”

## 2. Final objective

Trade qualified intra-candle micro-impulses on Deriv Gold and Wall Street 30:

```text
observe ticks → qualify movement → confirm direction → enter
→ optionally add only with continuation → bulk-close the EA basket
→ cooldown or lockout
```

“Limitless” means continuously searching for valid opportunities while obeying
hard risk limits. It never means unlimited entries, lots, or drawdown.

## 3. Non-negotiable truth

The EA must **not** enter on every fluctuation. Most tiny fluctuations are spread,
noise, or reversal risk. A movement is tradable only when expected travel is
materially larger than spread and execution cost.

“Sureball” means a high-confidence ruleset. It is not a guarantee of profit.

## 4. State machine

| State | Behavior |
| --- | --- |
| `OBSERVE` | Maintain rolling tick windows and symbol-cost statistics. |
| `ARMED` | A meaningful displacement/velocity event has started. |
| `CONFIRM` | Score direction, efficiency, persistence, structure, and costs. |
| `ENTERED` | Open the first minimum-risk position. |
| `STACKING` | Add only if continuation strengthens and existing basket is not losing. |
| `EXIT` | Close every EA position for this symbol and magic number. |
| `COOLDOWN` | Ignore the same oscillation so it cannot churn entries. |
| `LOCKOUT` | Stop after daily loss, margin danger, repeated losses, or bad execution. |

## 5. Micro-impulse detector

Use raw ticks, not candle-close entries. Keep rolling windows (initially 1, 3,
and 10 seconds) and normalize all prices by symbol tick size.

Calculate:

- **displacement**: signed net move from window start;
- **velocity**: displacement per second;
- **directional efficiency**: net displacement / total tick path;
- **persistence**: proportion of non-zero ticks moving in one direction;
- **spread ratio**: displacement / current spread;
- **micro break**: break of the recent rolling high/low;
- **volatility context**: movement relative to M1 ATR/median range;
- **tick activity**: tick-arrival acceleration, when reliable.

Hard gates:

- no stale quote or invalid tick/contract values;
- movement must exceed a configurable multiple of spread;
- spread must be below the symbol’s adaptive maximum;
- projected risk and margin must fit before any signal can trade.

## 6. Direction brain

Build a 0–100 confidence score:

| Evidence | Weight |
| --- | ---: |
| Signed velocity | 25 |
| Displacement vs spread/volatility | 20 |
| Directional efficiency | 20 |
| Micro high/low break | 15 |
| Tick persistence | 10 |
| M1/M5 context alignment | 10 |

Penalties can reduce the score for spread expansion, a strong opposite wick,
velocity collapse, stale ticks, or immediate failed breakout.

Phase 1 entry threshold: **75/100**. Entry direction is locked to the scored
direction. Do not hedge the same symbol.

### Regime choice

- **Continuation (Phase 1 default):** BUY a qualified upward impulse; SELL a
  qualified downward impulse.
- **Post-spike fade (disabled in Phase 1):** trade against an exhausted spike
  only after a separate rejection-and-opposite-velocity confirmation. Never
  infer exhaustion merely because a candle is large.

## 7. Entry and stacking

1. Open one position only after all signal and risk gates pass.
2. Assign a movement ID so the same oscillation cannot trigger repeatedly.
3. A second layer is allowed only when:
   - account/equity policy permits it;
   - confidence remains at least 80;
   - price has progressed in the basket direction;
   - the basket is at breakeven or profitable; and
   - minimum time/distance from the previous fill is satisfied.
4. Never add to a losing basket. No martingale, recovery grid, or lot multiplier.

For equity below $20, the default is **one layer**. The engine remains
stack-capable, but the capital governor overrides video-style multi-entry spam.

## 8. Basket exit

All exits act on this EA’s symbol + magic-number basket only.

Exit priority:

1. emergency margin/free-margin protection;
2. hard basket loss;
3. daily loss or consecutive-loss lockout;
4. net basket profit target after estimated costs;
5. confirmed opposite impulse;
6. velocity-fade exit while the basket is green;
7. maximum holding-time exit; then cooldown.

The normal profitable exit is **close the whole basket**, not “close winners and
leave losers.” This deliberately improves the risky behavior shown in the clip.

Initial adaptive profit target:

```text
max(estimated round-trip cost × cost multiplier, configured fraction of 1R)
```

Do not use a fixed dollar target until live Deriv symbol specifications are read.

## 9. $10 capital governor

- Risk budget is calculated from equity and a real emergency stop distance.
- Read broker `volume_min`, `volume_step`, tick value, tick size, and margin.
- If the minimum permitted volume exceeds the risk budget, **skip the trade**.
- Default maximum concurrent layers below $20 equity: **1**.
- Default basket risk ceiling: **2% equity**.
- Default daily loss lockout: **5% equity** or 3 consecutive basket losses,
  whichever occurs first.
- New entries require a safe projected margin level; emergency protection closes
  and locks out before stop-out territory.

These percentages are starting design limits, not proof that a $10 account can
safely trade Gold or Wall Street 30. Broker contract size may make the minimum
trade too large.

## 10. Symbol behavior

Use `_Symbol`; attach one EA instance per chart.

- **Gold profile:** Deriv Gold/XAUUSD alias discovered from Market Watch.
- **Wall Street 30 profile:** exact Deriv symbol selected by the user/chart.

Never share raw point thresholds between symbols. Normalize by tick size,
spread, tick value, ATR, and contract/margin properties.

## 11. Acceptance criteria before full EA release

- No entry can bypass spread, affordability, margin, or daily-loss gates.
- A $10 profile cannot open 1.00 lots or more than one default layer.
- No add occurs while the basket is losing.
- Every basket has profit, loss, time, and emergency exit paths.
- Bulk close filters by symbol + magic number and handles partial close failures.
- Continuation and fade signals cannot be active simultaneously.
- Tick-replay tests cover clean impulse, noisy chop, failed breakout, spread
  shock, reversal, insufficient margin, and close failure.
- Deriv demo forward testing is mandatory for both Gold and Wall Street 30.
- “Profitable” is accepted only after positive out-of-sample expectancy after
  spread/slippage; no win-rate or guaranteed-return claim is allowed.

## 12. Phase boundary

Phase 1 will implement only:

- symbol capability discovery;
- $10 MoneyManager/RiskGovernor;
- tick-window continuation detector;
- 75-point direction score;
- one entry (optional second layer disabled by default);
- basket profit/loss/time/opposite-signal bulk close; and
- cooldown/lockout.

The post-spike fade engine, adaptive learning, and more aggressive stacking are
later phases and require Phase 1 demo evidence.
