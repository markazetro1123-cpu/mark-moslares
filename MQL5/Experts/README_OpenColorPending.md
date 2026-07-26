# EA_OpenColorPending v2.00

**Design:** [`DESIGN_OpenColorPending.md`](./DESIGN_OpenColorPending.md)  
**EA:** `EA_OpenColorPending.mq5`

## Behavior
1. Wait **5 minutes** after candle open (anti-fakeout)
2. **GREEN** → BUY pending @ latest high  
   - trails **down only**  
   - floor = candle **open** (never chase up)
3. **RED** → SELL pending @ latest low  
   - trails **up only**  
   - ceiling = candle **open** (never chase down)
4. If `|price - open| >= 3.0` (buffer) → opposite pending **at open**
5. On fill → emergency SL + trail SL
6. Dynamic lot + dynamic entries (max 15), no martingale
7. XAUUSD + US30

## Install
1. Download the **full** `.mq5` (replace entire old file)
2. MetaEditor → Compile → expect **0 errors / 0 warnings**
3. Attach to XAUUSD or US30 → Algo Trading ON

Raw EA:  
`https://raw.githubusercontent.com/markazetro1123-cpu/mark-moslares/cursor/open-color-pending-b063/MQL5/Experts/EA_OpenColorPending.mq5`

Raw Design:  
`https://raw.githubusercontent.com/markazetro1123-cpu/mark-moslares/cursor/open-color-pending-b063/MQL5/Experts/DESIGN_OpenColorPending.md`
