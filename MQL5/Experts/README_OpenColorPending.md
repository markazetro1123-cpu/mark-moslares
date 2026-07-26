# EA_OpenColorPending

**Design (full):** [`DESIGN_OpenColorPending.md`](./DESIGN_OpenColorPending.md) — **v2.00 confirmed**

**EA file:** `EA_OpenColorPending.mq5` (implementation follows design v2.00)

## Quick summary
- 5-min structure delay before pending
- GREEN → BUY pending @ high (trail down only, floor = open)
- RED → SELL pending @ low (trail up only, ceiling = open)
- Buffer ≥ 3 points → opposite pending @ **open** only
- Fill → emergency SL + trail SL
- Dynamic lot + dynamic entries kept (max 15)

## Install
1. Use the full `.mq5` from this branch (replace entire file)
2. MetaEditor Compile → 0 errors / 0 warnings
3. Attach to XAUUSD or US30 → Algo Trading ON

Raw EA:
`https://raw.githubusercontent.com/markazetro1123-cpu/mark-moslares/cursor/open-color-pending-b063/MQL5/Experts/EA_OpenColorPending.mq5`

Raw Design:
`https://raw.githubusercontent.com/markazetro1123-cpu/mark-moslares/cursor/open-color-pending-b063/MQL5/Experts/DESIGN_OpenColorPending.md`
