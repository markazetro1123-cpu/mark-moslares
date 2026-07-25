# EA_ColorBurstScalper — MT5 (new)

Bagong EA base sa strategy mo:

```
MQL5/Experts/EA_ColorBurstScalper.mq5
```

## Strategy

1. **GREEN candle → BUY only** / **RED candle → SELL only**
2. **Buffer muna** bago mag-pending  
   Example SELL: open `4401`, buffer `1.0` → wait until price ≤ `4400`, then place SellStop
3. **One-way trailing pending**
   - SELL pending: always **below** price; tumaas ang price → tumaas din ang pending; bumaba ang price → **hindi** sumusunod pababa (para matamaan)
   - BUY pending: always **above** price; bumaba → bababa din; tumaas → **hindi** sumusunod pataas
4. **Aggressive lot** — lumalaki ang lot habang lumalaki ang capital (tier + high risk room)
5. **Burst basket TP** — kapag umabot sa maliit na profit (`InpBurstProfit`), **close lahat** ng basket; may basket trailing din

## Key inputs

| Input | Default | Meaning |
|---|---|---|
| `InpBufferDistance` | `1.0` | Buffer from candle open |
| `InpPendingOffset` | `0.2` | Pending gap from price |
| `InpMaxBasket` | `3` | Burst entries (max positions) |
| `InpBurstProfit` | `0.20` | Small profit → close basket |
| `InpBasketTrailStart` | `0.12` | Start basket trail |
| `InpBasketTrailGap` | `0.08` | Trail distance |
| `InpUseAggressiveLot` | `true` | TikTok-style lot growth |
| `InpRiskPercentStart` | `50.0` | Aggressive risk start |

## Install

1. Copy `EA_ColorBurstScalper.mq5` → MT5 `MQL5/Experts/`
2. MetaEditor → Compile (F7)
3. Attach sa XAUUSD / US30
4. Enable Algo Trading

Old file `EA_CandleBiasScalper.mq5` naka-keep pa sa repo, pero **ito ang bagong EA** na gamitin.

## Disclaimer

Trading is risky. Demo test first. Not financial advice.
