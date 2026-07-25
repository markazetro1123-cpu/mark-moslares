# CandleBiasScalper — MT5 EA

Candle-bias one-way trailing pending scalper for **XAUUSD** and **US30**.  
Works on **any timeframe** (chart TF = EA TF). Built for Deriv / Tickmill compatibility.

## Strategy (locked)

1. Bias from candle Open: below = SELL priority, above = BUY priority  
2. Arm only after `BufferDistance` from Open  
3. BUY stop above price (trail **down only**), SELL stop below price (trail **up only**)  
4. Priority + counter pending; **1 open position** max with flip  
5. Secure profit floor then trail for more  
6. Smart risk: start **50%** room, **-5% per equity tier**, dynamic lot growth  

## Install

1. Copy:
   - `MQL5/Experts/EA_CandleBiasScalper.mq5` → MT5 `MQL5/Experts/`
   - `MQL5/Include/CBR_Utils.mqh` → `MQL5/Include/`
   - `MQL5/Include/CBR_Risk.mqh` → `MQL5/Include/`
2. Compile in MetaEditor (F7)
3. Attach to XAUUSD or US30 chart (any TF)
4. Enable **Algo Trading**

## Core inputs

| Input | Default | Meaning |
|-------|---------|---------|
| `InpBufferDistance` | 1.0 | Distance from open before arming |
| `InpPendingOffset` | 0.2 | Pending gap from current price |
| `InpSecureProfit` | 0.2 | Secure floor |
| `InpTrailDistance` | 0.1 | Trail gap from current price |
| `InpEmergencyStopDist` | 5.0 | Emergency SL distance |
| `InpUseSmartRisk` | true | Tiered lot/risk manager |

## Files

```
MQL5/Experts/EA_CandleBiasScalper.mq5
MQL5/Include/CBR_Utils.mqh
MQL5/Include/CBR_Risk.mqh
```

## Disclaimer

Trading is risky. Test on demo first. Not financial advice.
