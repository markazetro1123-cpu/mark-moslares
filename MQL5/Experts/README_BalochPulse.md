# EA_BalochPulse — Architecture v2 (locked behavior)

Single file:

```
MQL5/Experts/EA_BalochPulse.mq5
```

## Important
Core behavior is **inside the engines**, not adjustable filter soup.  
Inputs are only account/broker/session-clock settings.

## Always-on engines
1. **Session Guard** — NY–London only (default PH 8PM–5AM)
2. **News/FOMC Guard** — hard blackouts 20:30–20:40 & 21:30–21:40 + high-impact USD + FOMC
3. **Adaptive Tick Engine** — no fixed 30-tick window; window adapts to tick speed
4. **Candle Memory** — confirms impulse / detects threat
5. **Risk Manager (CEO)** — decides mode, lot, entries with common sense + memory
6. **Same-price Burst Entry** — multi-entry at same price band only
7. **Smart Self-Exit** — closes when profit is threatened (main exit)

## Locked architecture rules
- No spread filter
- No martingale (same lot per cycle)
- Max entries hard cap = **15**
- `$30–$50` can intelligently open **2–3** entries when clean
- Impulse → small pullback → burst enter
- Lot/entries grow with equity + signal quality via Risk Manager
- XAUUSD and US30 use **same logic**
- Emergency SL = safety net only

## Minimal inputs
- Magic / Risk% / MinLot / MaxLotCap / Slippage / AllowBuy/Sell
- Session clock (TZ + start/end)
- Print logs

## State machine
```
IDLE → BIAS_DETECT → IMPULSE_CONFIRM → WAIT_PULLBACK → ENTER_BURST → MANAGE → SMART_EXIT → COOLDOWN
```

## Install
Copy one file → Compile → attach XAUUSD or US30 → Algo Trading ON.  
For live: keep session clock correct for your local TZ (PH=8).
