# EA_PulsePAScalper v1.01 — M1 Pure Price-Action Scalper

```
MQL5/Experts/EA_PulsePAScalper.mq5
```

Walang indicator. Pure OHLC price action. **Defaults tuned for M1 + NY session.**

## Strategy

**Micro-range break + impulse candle**

1. Micro-range = last `6` closed M1 candles (~6 minutes)  
2. Signal candle must **break + close** beyond range, with:
   - body/range >= `50%`
   - min size `50` points (raise for noisy XAU/US30)
   - close near break extreme
3. Market entry on next new M1 bar  
4. SL beyond structure + buffer  
5. TP = SL × `1.2` R:R  
6. Break-even + max hold `8 minutes`

## M1 default settings

| Input | Value | Why |
|---|---|---|
| Chart | **M1** | Intended TF |
| Range bars | 6 | Short scalp context |
| Body ratio | 0.50 | Active but still filtered |
| Min candle points | 50 | Start point — calibrate per symbol |
| Break buffer | 3 pts | Small confirmation |
| R:R | 1.2 | Faster scalp exits |
| Max hold | 480s (8m) | Don't turn M1 into swing |
| Cooldown | 20s | Allows frequent re-entries |
| Max trades/day | 50 | Cap for busy NY day |
| Risk / trade | 0.4% | Lower because more entries |
| Daily loss lock | 3% | Hard pause |
| Session | 15:00–23:00 server | Approx NY on many GMT+2/3 brokers |

**Expected NY-session entries on M1:** roughly **8–20** quality trades (not every minute). Cap = 50/day.

## Session note

`15:00–23:00` assumes broker server ≈ GMT+2/GMT+3.  
I-check ang server time sa Market Watch → adjust `InpSessionStartHour` / `InpSessionEndHour` kung iba ang broker mo.

## Risk rules

- No martingale / no grid  
- One position at a time  
- Spread filter + cooldown + daily loss lock  
- Lot from risk % (or fixed lot)

## Install (MT5)

1. Copy `EA_PulsePAScalper.mq5` → `MQL5/Experts/`
2. Compile in MetaEditor
3. Attach on **M1** chart
4. Enable **Algo Trading**
5. Demo-test first; tune `InpMinCandlePoints` per symbol

## Quick tune (M1)

- **Too few trades:** `InpMinCandlePoints=30`, `InpMinBodyRatio=0.45`, `InpRangeBars=5`
- **Too noisy / many losers:** `InpMinCandlePoints=80–120` (XAU), `InpMinBodyRatio=0.55`, tighter session
- **Gold (XAUUSD):** usually raise min candle points after watching 1–2 demo sessions
- **US30:** same — calibrate points to your broker digits

Walang “sure win” EA — always demo before live.
