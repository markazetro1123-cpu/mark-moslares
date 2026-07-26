# EA_PulsePAScalper v1.02 — M1 Pure Price-Action Scalper

```
MQL5/Experts/EA_PulsePAScalper.mq5
```

Walang indicator. Pure OHLC. **M1 + NY session.**  
Scaled risk for small capital (~$30 start). **No daily loss pause** — keep trading while signals exist.

## Strategy

**Micro-range break + impulse candle**

1. Micro-range = last `6` closed M1 candles  
2. Signal candle must break + close beyond range with body quality filters  
3. Market entry on next M1 bar  
4. SL beyond structure, TP = SL × `1.2`  
5. Break-even + max hold `8 minutes`

## Scaled risk (default ON)

| Equity | Risk % / trade |
|---|---|
| < $50 (e.g. $30 start) | **25%** |
| $50 – $100 | 15% |
| $100 – $250 | 8% |
| $250 – $500 | 4% |
| $500 – $1000 | 2% |
| >= $1000 | 1% |

- `InpMaxDailyLossPct = 0` → **OFF** (no daily stop)  
- `InpMaxTradesPerDay = 0` → **unlimited**  
- Habang lumalaki ang capital, automatic bumababa ang risk %

## Other M1 defaults

| Input | Value |
|---|---|
| Session | 15:00–23:00 server (approx NY on GMT+2/3) |
| Cooldown | 20s |
| R:R | 1.2 |
| Max hold | 8 min |

## Install (MT5)

1. Copy `EA_PulsePAScalper.mq5` → `MQL5/Experts/`
2. Compile → attach on **M1**
3. Enable **Algo Trading**
4. Demo-test first; tune `InpMinCandlePoints` per symbol

## Warning

25% risk on ~$30 is aggressive — a few losses can wipe the account fast. That’s by request for small-capital growth mode. Scale tiers lower the % as equity grows.
