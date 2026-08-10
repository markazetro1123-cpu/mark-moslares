# Limitless Scalp Brain — Money Management & Symbol Notes

## $10 capital starter profile

Goal: same video **behavior class**, survivable sizing.

```text
Equity = 10 USD (example)

RiskPercentPerLayer = 1.5%  -> risk_money ~= 0.15 USD
MaxLayers = 2               -> max concurrent risk budget ~0.30 USD (not additive blindly)
DailyLossLimit = 1.00 USD   -> 10% day kill (tune; stay strict early)
BasketProfitMoney = 0.20–0.50 USD (scale with lot)
BasketMaxLossMoney = 0.40–0.80 USD
MinSecondsBetweenEntries = 2–5
```

### Lot normalize (MT5)

```text
raw_lot = risk_money / (sl_distance_in_value_per_lot)
OR if no hard SL distance: use min lot only on $10

lot = floor(raw_lot / volume_step) * volume_step
lot = clamp(lot, volume_min, volume_max)
if lot < volume_min: skip entry (cannot afford)
```

On many Deriv CFD symbols, **volume_min may already be the only safe choice** at $10. Prefer skip over forcing oversized risk.

### Layer policy by equity

| Equity | MaxLayers | Notes |
|--------|-----------|-------|
| < $20 | 1 | single-shot scalp |
| $20–$100 | 2 | capped stack |
| > $100 | 2–3 | still no video-style spam |

## Sureball confirmation score

```text
score = 0
+1 velocity aligned
+1 body/extreme aligned
+1 micro-structure break aligned
-2 spread > max
-2 opposing rejection wick

enter only if score >= 2 and RiskGovernor OK
```

## Bulk close priority

1. `BasketProfitMoney` or `BasketProfitPoints`
2. `BasketMaxLossMoney`
3. Margin level abort (e.g. < 200% on tiny accounts — tune to broker)
4. Time-stop
5. Fade exit when small green + impulse dead

## Deriv symbol checklist (OnInit)

User broker: **Deriv**. Confirm Market Watch exact names:

- Gold alias (e.g. `XAUUSD`, `XAUUSDm`, …)
- Index: **Wall Street 30** (sometimes shown as US30-style name)

Validate per symbol:

- `SYMBOL_TRADE_MODE`
- volume min/step/max
- point/tick value/tick size
- typical spread → set `InpMaxSpread`

Keep separate input presets:

```text
PresetGold: ATRMult, VelocityPoints, MaxSpread, ProfitPoints
PresetUS30: ATRMult, VelocityPoints, MaxSpread, ProfitPoints
```

## Anti-patterns on $10

- Fixed lot `1.00`
- 5+ layers in one impulse
- Hedging both sides
- Martingale after loss
- No daily kill switch
- Hardcoding only XAUUSD
