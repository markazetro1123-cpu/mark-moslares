# CandleBiasScalper v2 — MT5 EA (single file)

Isang file lang kailangan i-copy:

```
MQL5/Experts/EA_CandleBiasScalper.mq5
```

## Install

1. MT5 → **File → Open Data Folder**
2. Copy `EA_CandleBiasScalper.mq5` → `MQL5/Experts/`
3. MetaEditor → open file → **Compile (F7)**
4. Attach sa XAUUSD o US30 chart (any TF)
5. Enable **Algo Trading**

## What changed in v2 (why v1 lost in tests)

| Problem in v1 | v2 fix |
|---|---|
| Counter pending + flip = whipsaw | `InpPriorityOnly=true`, `InpAllowFlip=false` by default |
| Fixed 0.2 secure / 0.1 trail often < spread | ATR-based secure/trail + min N×spread |
| 50% risk blew accounts | Default **2%** risk via emergency SL distance |
| No spread / cooldown filter | Max spread filter + cooldown after close |

## Strategy (still the same core)

- Candle-open bias (SELL below / BUY above)
- Buffer arming → BuyStop / SellStop
- One-way pending trail (BUY down-only, SELL up-only)
- Secure profit then trail
- **Default: bias side only** (no counter/flip)

## Recommended first retest defaults

Leave inputs at defaults. Optional:
- XAUUSD M5/M15 demo
- `InpMaxSpreadPoints` tighten if broker spread is usually lower
- `InpFixedLot = min lot` first if you want pure signal quality test

## Disclaimer

Trading is risky. Demo/Strategy Tester first. Not financial advice.
