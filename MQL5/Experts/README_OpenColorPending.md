# EA_OpenColorPending v1.00

Single file:

```
MQL5/Experts/EA_OpenColorPending.mq5
```

## Entry strategy (new)
1. Read **current candle open**
2. Price below open = **RED** → SELL pending only at **latest low** (trails down)
3. Price above open = **GREEN** → BUY pending only at **latest high** (trails up)
4. Detect **previous candle HIGH/LOW**
5. On fill: **trail SL** (example: price 4399 → SL 4399.5)
6. After **profit** on that candle → **cooldown** until next candle
7. Emergency SL always set

## Kept from before
- Dynamic lot by equity
- Dynamic entry count (`$30–$50` → 2–3, hard max 15)
- No martingale (same lot cycle)
- XAUUSD + US30

## Install
Copy → Compile → attach XAUUSD/US30 any TF → Algo Trading ON.
