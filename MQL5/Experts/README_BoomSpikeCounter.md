# EA_BoomSpikeCounter v1.3 — single file

```
MQL5/Experts/EA_BoomSpikeCounter.mq5
```

Works on:
- **Boom 1000 Index**
- **Boom 100 Index**
- **Any attached timeframe** (`WorkTF = PERIOD_CURRENT` by default)

## Install
1. Copy `EA_BoomSpikeCounter.mq5` → MT5 `MQL5/Experts/`
2. Compile (F7)
3. Attach to Boom 1000 or Boom 100 chart (any TF)
4. Enable Algo Trading

## Strategy (frozen spec)
1. Closed Green → closed Red → open **1 SELL**
2. SELL SL = previous Green close + `SL_Buffer`
3. Place **3 Buy Stops** at SELL SL price (same lot)
4. Trail SELL SL + Buy Stops **down only**
5. Early exit SELL if forming Green overlaps previous Red body
6. If Buy Stop fills → close SELL, delete leftovers → **BUY mode**
7. BUY exit on **confirmed Red** candle close
8. Lot: start 1.00, WIN +0.50, LOSS −0.50 (min 1 / max 20) — reduce for margin/broker
9. Dynamic emergency basket loss by equity tier

## Boom 100 note
If broker min volume is below `1.00`, EA still normalizes to broker `VOLUME_MIN` for execution. Adjust `StartLot` / `MinLot` in Inputs if needed for your account size.

## Disclaimer
Synthetic indices are high risk. Demo test first. Not financial advice.
