# EA_OpenColorPending v1.20 (clean build)

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
1. Download the **full** `.mq5` file (do not paste fragments into an old file like `GREENPENDING_2.mq5`)
2. MetaEditor → Compile → expect **0 errors / 0 warnings**
3. Attach to XAUUSD or US30 chart → Algo Trading ON

Raw:
`https://raw.githubusercontent.com/markazetro1123-cpu/mark-moslares/cursor/open-color-pending-b063/MQL5/Experts/EA_OpenColorPending.mq5`
