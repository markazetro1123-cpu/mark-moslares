# EA_OpenColorPending v2.10

**Design:** [`DESIGN_OpenColorPending.md`](./DESIGN_OpenColorPending.md)  
**EA:** `EA_OpenColorPending.mq5`

## Behavior
1. Wait **5 minutes** after candle open (anti-fakeout)
2. **GREEN** → BUY pending @ latest high (trail down only, floor = open)
3. **RED** → SELL pending @ latest low (trail up only, ceiling = open)
4. Buffer `|price - open| >= InpOpenBuffer` → opposite pending **at open**
5. **Adjustable RR secure** (inputs):
   - `InpSecureTrigger` — start securing when profit ≥ this (default `1.0`)
   - `InpSecureLock` — locked profit once triggered (default `1.0`, was hard `0.5`)
   - `InpTrailStep` — continue trail after lock (`0` = use SecureLock)
6. **Session time filter** (inputs, PH default 20:00–05:00)
7. Dynamic lot + dynamic entries (max 15)
8. XAUUSD + US30

## Install
1. Download the **full** `.mq5` (replace entire old file)
2. MetaEditor → Compile → **0 errors / 0 warnings**
3. Attach to XAUUSD or US30 → set RR + session inputs → Algo Trading ON

Raw EA:  
`https://raw.githubusercontent.com/markazetro1123-cpu/mark-moslares/cursor/open-color-pending-b063/MQL5/Experts/EA_OpenColorPending.mq5`
