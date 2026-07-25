# EA_BoomSpikeCounter v1.31 — single file

```
MQL5/Experts/EA_BoomSpikeCounter.mq5
```

Works on **Boom 1000**, **Boom 100**, any attached TF.

## v1.31 fixes
1. **BUY not entering bug** — when SELL hit SL, EA used to delete Buy Stops before they filled. Now it **waits** for BuyStop fills / `OnTradeTransaction`.
2. **Slippage realism** — Inputs:
   - `SlippagePoints` (default 50) — deviation for market fills
   - `InpEntrySlipPrice` — extra adverse SELL slip (price)
   - `InpUseChartSpread` / `InpSpreadFloorPts` — chart spread awareness

## Tester tip (para hindi “sunog” sa live)
Use modeling: **Every tick based on real ticks** (kung available).  
Set `SlippagePoints` close to what you see sa live (try 30–100).  
Optional: set `InpEntrySlipPrice` (e.g. `0.10`–`0.50` on Boom) para mas masakit ang fills sa tester.

## Install
Copy → Compile → attach Boom chart → Algo Trading ON.
