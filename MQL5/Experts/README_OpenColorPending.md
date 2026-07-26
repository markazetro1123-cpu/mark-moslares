# EA_OpenColorPending v2.20

**Design:** [`DESIGN_OpenColorPending.md`](./DESIGN_OpenColorPending.md)  
**EA:** `EA_OpenColorPending.mq5`

## Behavior
1. Wait **5 minutes** after candle open
2. **GREEN** → main BUY @ high (trail down, floor=open)  
   + **Counter SELL Stop @ open** if buffer OK
3. **RED** → main SELL @ low (trail up, ceiling=open)  
   + **Counter BUY Stop @ open** if buffer OK
4. Adjustable RR secure (`InpSecureTrigger` / `InpSecureLock` / `InpTrailStep`)
5. Session time filter (PH default 20:00–05:00)
6. Dynamic lot + entries (max 15) · XAUUSD + US30

## Counter inputs
| Input | Default | Meaning |
|---|---|---|
| `InpAllowCounterBuy` | true | RED + buffer → BUY Stop @ candle open |
| `InpAllowCounterSell` | true | GREEN + buffer → SELL Stop @ candle open |
| `InpOpenBuffer` | 3.0 | Min distance from open before counter arms |

## Install
1. Replace entire `.mq5` file
2. MetaEditor Compile → **0 errors / 0 warnings**
3. Attach chart → set Counter / RR / Session inputs → Algo Trading ON

Raw:  
`https://raw.githubusercontent.com/markazetro1123-cpu/mark-moslares/cursor/open-color-pending-b063/MQL5/Experts/EA_OpenColorPending.mq5`
