# CandleBiasScalper — MT5 EA (single file)

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

Walang extra `.mqh` include files.

## Strategy

- Candle-open bias (SELL below / BUY above)
- Buffer distance arming
- BuyStop above (trail down only) / SellStop below (trail up only)
- Priority + counter, **1 open position**, flip
- Secure profit then trail
- Smart risk: 50% start, -5% per tier, dynamic lot

## Disclaimer

Trading is risky. Demo test first. Not financial advice.
