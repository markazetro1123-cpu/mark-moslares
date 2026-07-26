# EA_OpenColorPending v1.10 (clean build)

```
MQL5/Experts/EA_OpenColorPending.mq5
```

## Strategy
1. Detect current candle **open**
2. Below open = **RED** → SELL pending at latest **low** (trails down only)
3. Above open = **GREEN** → BUY pending at latest **high** (trails up only)
4. Tracks previous candle **HIGH/LOW**
5. On fill → trail SL (example: `4399` → `4399.5`)
6. After profit close → lock until next candle
7. Emergency SL always set

## Kept
- Dynamic lot by equity
- Dynamic entries (`$30–$50` → 2–3, max 15)
- No martingale
- XAUUSD + US30

## Install
Copy one file → MetaEditor Compile (expect 0 errors / 0 warnings) → attach chart → Algo Trading ON.
