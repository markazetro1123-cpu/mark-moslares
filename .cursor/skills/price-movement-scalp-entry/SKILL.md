---
name: price-movement-scalp-entry
description: Encode ExpertGold1-style price-movement / impulse-mash entries for MT5 scalping EAs without inventing indicator formulas. Use when the user says entry is price movement, micro-impulse, fluctuation scalp, mash entries, or asks what triggers the ExpertGold1-style bot.
---

# Price-Movement Scalp Entry

## Locked trigger class

Entry trigger is **price movement / micro-impulse**, not classic indicators.

Multi-video evidence (`docs/VIDEO_EVIDENCE_MATRIX.md`) shows naked-chart one-click
SELL/BUY mashing during live candle fluctuation. No RSI/MA/MACD panels appear.

Do **not** re-ask “what is the entry trigger?” after the user has stated
price-movement scalping and the videos confirm that class. Encode it.

## What is OBSERVED vs UNKNOWN

| Item | Label |
| --- | --- |
| Naked chart, one-click mash | OBSERVED |
| Same-direction tight stacks | OBSERVED |
| Bulk Operations exits | OBSERVED |
| Exact human tick thresholds | UNKNOWN |
| Indicator crossover entry | CONTRADICTED |

Phase 1 replaces UNKNOWN human instinct with **deterministic tick windows** from
`docs/FINAL_BEHAVIOR_SPEC.md` (1s/3s/10s displacement, velocity, efficiency,
persistence, spread ratio; direction score ≥75).

## EA encoding checklist

1. Tick Window Engine qualifies movement vs spread/noise.
2. Direction Confidence Engine scores side ≥75 before first entry.
3. Phase 1: continuation-only; post-spike fade stays disabled.
4. Cap layers for $10 equity (default 1 below $20); never TikTok 1.00 lots.
5. Basket bulk close on profit target / loss / emergency — never orphan losers.
6. Emit reason codes for accept/reject (never silent “instinct”).

## Forbidden

- Inventing a secret indicator and calling it instinct
- Entering every flicker without cost/spread gates
- Martingale / add-to-loser / unlimited mash depth
- Claiming the videos prove long-term profitability

## Related

- Video profile: [expertgold1-video-scalp](../expertgold1-video-scalp/SKILL.md)
- Brain / MM: [limitless-scalp-brain](../limitless-scalp-brain/SKILL.md)
- Audit: [scalp-replication-audit](../scalp-replication-audit/SKILL.md)
