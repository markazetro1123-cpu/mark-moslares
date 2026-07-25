# EA_ColorBurstScalper — single file

Copy this one file only:

```
MQL5/Experts/EA_ColorBurstScalper.mq5
```

## Install
1. MT5 → File → Open Data Folder → `MQL5/Experts/`
2. Paste the `.mq5` file
3. MetaEditor → Compile (F7)
4. Attach on **any timeframe** (M1/M5/M15/H1…) — EA uses that chart TF
5. Enable Algo Trading

## What it does
- **RED candle → SELL** / **GREEN → BUY**
- First entry: wait **buffer** from candle open (default `1.0`)
- SellStop below / BuyStop above, **one-way trail**
- After close: immediate re-entry pending at **current ± 1.0**, then trail
- **Burst basket TP** (small profit close all) + basket trail
- Aggressive lot growth with capital
- Active only **8:00 PM – 5:00 AM PH time (UTC+8)**

## Disclaimer
Trading is risky. Demo first. Not financial advice.
