# Limitless Scalp Brain — Money Management & Symbol Notes

## $10 capital starter profile

Goal: same video **behavior class**, survivable sizing.

```text
Equity = 10 USD (example)

RiskPercentPerLayer = 1.5%  -> risk_money ~= 0.15 USD
BasketRiskCeiling = 2%      -> total basket risk <= 0.20 USD
MaxLayers = 1               -> below $20 equity
DailyLossLimit = 5%         -> 0.50 USD day lockout
BasketProfit = adaptive     -> must exceed estimated round-trip costs
MinSecondsBetweenEntries = 2–5
```

### Lot normalize (MT5)

```text
raw_lot = risk_money / (sl_distance_in_value_per_lot)
No valid emergency stop distance -> no trade

lot = floor(raw_lot / volume_step) * volume_step
lot = clamp(lot, volume_min, volume_max)
if raw_lot < volume_min: skip entry (do not force minimum)
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
+25 signed velocity
+20 displacement vs spread/volatility
+20 directional efficiency
+15 micro high/low break
+10 tick persistence
+10 M1/M5 context

apply penalties for spread shock, stale ticks, failed breakout, opposing rejection
enter only if score >= 75 and RiskGovernor OK
add only if score >= 80 and basket is not losing
```

## Bulk close priority

1. emergency margin/free-margin protection
2. `BasketMaxLossMoney`
3. daily/consecutive-loss lockout
4. net basket profit target after costs
5. confirmed opposite impulse
6. fade exit when small green + impulse dead
7. time-stop

Close the complete symbol+magic basket. Do not close only winners and leave
losers orphaned.

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

Prefer normalized thresholds derived from tick size, spread, tick value, and
volatility. Raw Gold point values must not be reused for Wall Street 30.

## Anti-patterns on $10

- Fixed lot `1.00`
- 5+ layers in one impulse
- Hedging both sides
- Martingale after loss
- No daily kill switch
- Hardcoding only XAUUSD
