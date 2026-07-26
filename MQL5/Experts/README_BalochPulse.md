# EA_BalochPulse — ARCH v2.50 (rules enforced)

File:

```
MQL5/Experts/EA_BalochPulse.mq5
```

Must show on chart comment: **`BalochPulse ARCH v2.50`**

## Locked rules
| ID | Rule |
|---|---|
| R1 | NY–London session only (new entries) |
| R2 | Hard blackout 20:30–20:40 & 21:30–21:40 |
| R3 | High-impact USD + FOMC block |
| R4 | Adaptive tick imbalance (no fixed 30) |
| R5 | Candle memory agree |
| R6 | Impulse → pullback → enter |
| R7 | Risk Manager decides lot + entries |
| R8 | $30–$50 can open 2–3 when clean |
| R9 | Max 15 hard cap |
| R10 | Same-price burst (one shot / one band) |
| R11 | No martingale |
| R12 | Smart self-exit main exit |
| R13 | No spread filter |
| R14 | XAUUSD + US30 same logic |
| R15 | Always-on engines + on-chart rule monitor |

## Minimal inputs
Magic / Risk% / lots / slippage / buy-sell / session clock / logs

## Verify
1. Compile v2.50
2. Attach chart
3. Look top-left **Comment** panel (`RuleNow: ...`)
4. Journal logs start with `R1`…`R12` tags
