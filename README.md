# EA_PulsePAScalper v1.00 — Pure Price-Action Scalper

```
MQL5/Experts/EA_PulsePAScalper.mq5
```

Walang indicator. Pure OHLC price action lang.

## Ano ang strategy

**Micro-range break + impulse candle**

1. Kunin ang high/low ng last `N` closed candles (default 4) → micro-range  
2. Hintayin ang **signal candle** (bar 1 / last closed) na:
   - **Break + close** beyond the range (with small buffer)
   - Strong body (`body / range >= 55%` default)
   - Minimum candle size (points)
   - Close near the break side (outer 35%)
3. Enter market on the **next new bar**
4. SL beyond structure (range extreme / signal wick + buffer)
5. TP = SL distance × R:R (default **1.5**)
6. Optional: break-even lock + time exit (scalp hold cap)

BUY and SELL both supported. Masipag siya kapag maraming clean breaks, pero **tahimik** kapag walang quality signal.

## Defaults (scalping-friendly)

| Setting | Default | Notes |
|---|---|---|
| Chart TF | M1 or M5 | I-attach sa preferred scalp TF |
| Range bars | 4 | Tighter = more signals |
| Body ratio | 0.55 | Higher = stricter / fewer trades |
| Risk / trade | 0.5% | Keep small for active scalping |
| Max daily loss | 3% | Auto-pause new entries |
| Cooldown | 45s | After a close |
| Session | 08:00–20:00 server | Turn off filter for 24h |
| Max trades/day | 40 | Safety cap |

## Risk rules built-in

- No martingale / no grid  
- One position at a time  
- Spread filter  
- Daily loss lock  
- Lot size from risk % (or fixed lot)  
- TP must beat spread noise  

## Install (MT5)

1. Copy `EA_PulsePAScalper.mq5` → `MQL5/Experts/`
2. Compile in MetaEditor
3. Attach to chart (`XAUUSD` / indices / majors — test first)
4. Enable **Algo Trading**
5. Start on **demo** and tune `InpMinCandlePoints` per symbol

## Quick tune tips

- **Too few trades:** lower `InpMinBodyRatio` (e.g. 0.45), lower `InpMinCandlePoints`, shorter range (`3`)
- **Too many losers:** raise body ratio / min candle points, tighten session to London+NY only
- **Gold (XAUUSD):** start `InpMinCandlePoints` around `80–150` on M5 (broker-dependent)
- **US30 / indices:** usually needs larger point thresholds — demo-calibrate

## Honest note

Walang EA ang “sure win”. Ito ay rules-based scalper with filters — profitability depends on symbol, broker spread/commission, session, and your risk settings. Always demo-test before live.
