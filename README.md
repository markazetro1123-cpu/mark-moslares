# EA_ColorBurstScalper v1.10 — single file

```
MQL5/Experts/EA_ColorBurstScalper.mq5
```

## Why v1 was losing
- TP `0.20` vs SL `5.0` → bad R:R  
- Re-entry even after **loss** → revenge loop  
- Basket `3` + **50% risk** → account blowups  
- Spread could be larger than burst TP  

## v1.10 changes (same strategy flow)
- Burst TP default `0.50`, emergency SL `1.50`
- Re-entry **only after win** (+ cooldown after loss)
- Max basket default `1`
- Risk capped ~`2%` (lot still grows by equity tier)
- Spread filter + burst must beat spread

## Session
Active **8:00 PM – 5:00 AM PH (UTC+8)** only.

## TF
Uses **whatever chart timeframe** you attach it on.

## Install
Copy one file → Experts → Compile → attach → Algo Trading ON.
