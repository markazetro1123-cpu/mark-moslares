# EA_BalochPulse — Adaptive Tick Pulse (XAUUSD + US30)

Single file:

```
MQL5/Experts/EA_BalochPulse.mq5
```

Copy that one file only → MetaEditor → Compile → attach to chart.

## Works on
- **XAUUSD** (Gold)
- **US30** family (`US30`, `US30Cash`, `DJ30`, `WallStreet30`, etc.)
- Brokers: **Tickmill** / **Deriv**
- Same logic on both symbols (auto lot/stops/same-price band)

## Engines (always-on)
1. Session Guard — NY–London only (default PH TZ +8, 20:00→01:00)
2. News/FOMC Guard — hard blackouts **20:30–20:40** & **21:30–21:40** + MT5 calendar high-impact USD + FOMC
3. Adaptive Tick Imbalance — no fixed 30-tick window
4. Candle Memory — confirms impulse / threat
5. Risk Manager — decides mode, lot, entries
6. Same-price Burst Entry — multi-entry at same price band
7. Smart Self-Exit — closes when profit is threatened

## Locked rules
- No spread filter
- No martingale (`SameLotPerCycle=true`)
- Max entries hard cap: **15**
- Small capital **$30–$50** can intelligently open **2–3** entries when clean
- Lot/entries grow with equity + signal quality
- Goal feel: larger wins, small drawdown

## v1.10 entry frequency patch
Filters loosened so EA is not too quiet:
- Lower imbalance thresholds (`0.55/0.52`)
- Pullback **not required** by default (`InpRequirePullback=false`)
- Candle confirm **off** by default (tick pressure enough)
- Calendar default = **FOMC only** (`InpBlockHighImpactUSD=false`)
- Session widened to **8PM–5AM PH**
- Hard blackouts kept (20:30–20:40 & 21:30–21:40)

## Risk Manager modes
- `AGGRESSIVE` — clean strong signal, low DD
- `NORMAL` — balanced
- `DEFENSIVE` — weaken / DD rising → stop adds
- `LOCKDOWN` — no new entries, protect/exit focus

## Install
1. Copy `EA_BalochPulse.mq5` into `MQL5/Experts/`
2. Compile
3. Attach to XAUUSD or US30 chart (any TF)
4. Enable Algo Trading
5. Ensure terminal economic calendar is available for news filter

## Notes
- Main exit is **smart self-close**, emergency SL is safety net only
- Outside session / during news: no new entries; open trades still managed
- Calendar filter needs MT5 calendar data (USD high-impact + FOMC keywords)
