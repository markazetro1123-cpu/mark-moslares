---
name: impulse-scalp-ea
description: Design and build MT5 impulse scalping Expert Advisors that enter on intra-candle price fluctuations, trade aggressively but with profit discipline, and bulk-close when floating profit hits target. Use when the user asks for scalping EA, spike/impulse detector, price-movement bot, gold/XAUUSD scalp automation, bulk close on profit, or an EA with trader-like instinct.
---

# Impulse Scalp EA

## Design north star (user intent)

Build an EA with “utak” / scalper instinct:

> Sa kada price movement kikita ako — makakapag-scalping ako aggressive pero profitable. Sa isang candle madaming taas-baba na price movement; sa kada fluctuation makasabay ako mag-scalping. Pag nag-profit, close na.

Translate that into code as **detect → enter with move → manage basket → bulk close on profit**. Never treat “instinct” as mystery — encode it as measurable engines.

## Default product assumptions

- Platform: **MetaTrader 5** (MQL5)
- Primary symbol: **XAUUSD** (also support major FX pairs)
- Style: **momentum impulse scalping** (ride micro moves), not long swing
- Close style: **basket / bulk close** when profit target hit
- Runtime: EA runs on **desktop/VPS**; mobile MT5 is monitor-only

## Non-negotiable risk rules

- No martingale by default
- No unbounded grid averaging
- Max layers hard-capped (start: 1–3)
- Spread gate before every entry
- Session filter (prefer London / NY / overlap)
- News filter for high-impact events when available
- Daily loss kill switch + max trades/day
- One symbol focus until proven
- Always demo-test before live

If user requests martingale/grid, warn about blow-up risk and require explicit opt-in + hard caps.

## EA architecture (required modules)

Implement as separate concerns (functions/classes), not one giant `OnTick`:

1. **ImpulseDetector** — “may galaw”
2. **DirectionFilter** — which side to scalp
3. **EntryEngine** — open / optional scale-in
4. **BasketManager** — track layered positions
5. **BulkCloseManager** — “profit na, close lahat”
6. **RiskGovernor** — spread/session/news/daily limits

Details and formulas: [reference.md](reference.md)

## Core behavior loop

```text
on each tick / new micro-window:
  if RiskGovernor blocks -> return

  impulse = ImpulseDetector.evaluate()
  if impulse.active and EntryEngine.canOpen():
      open in impulse.direction
      optional scale-in only if still strong and under max layers

  if positions open:
      if floating profit >= target -> close all (bulk)
      if floating loss >= max basket loss -> close all
      if impulse faded and small profit -> close all (instinct exit)
      if time-stop hit -> close all
```

## Impulse detection (minimum viable)

Flag a scalp opportunity when most of these fire:

- Range / displacement vs ATR(M1) expands (e.g. range >= `K * ATR`)
- Tick velocity burst (points moved per short window)
- Candle body supports direction (close near extreme)
- Tick volume >= multiple of recent average
- Spread <= `MaxSpread`

Do **not** use Level 2 / DOM as primary forex/gold CFD trigger (often synthetic/spoofable).

## Entry / scale-in policy

**Phase 1 (ship first):**
- Single position per impulse
- Fixed lot or risk-% lot
- No adds

**Phase 2 (only after Phase 1 stable):**
- Scale-in with impulse continuation
- Add only if floating not deep red
- Max layers 2–4
- Same magic number / comment tag for basket

Direction:
- Primary: impulse direction
- Optional confirm: micro EMA slope or break of recent micro swing

## Exit policy (matches user style)

Priority order:

1. **Bulk close on money target** (`BasketProfitMoney`)
2. Or **bulk close on points target** (`BasketProfitPoints`)
3. Emergency basket SL
4. Momentum fade / rejection wick exit when small green
5. Time-stop (avoid zombie positions)

Partial closes are optional later; default user style is **all-or-nothing basket close**.

## Inputs to expose (baseline)

- `InpLot` / `InpRiskPercent`
- `InpATRPeriod`, `InpATRMult`
- `InpVelocityPoints`, `InpVelocitySeconds`
- `InpVolumeMult`
- `InpMaxSpread`
- `InpMaxLayers`
- `InpBasketProfitMoney`, `InpBasketProfitPoints`
- `InpBasketMaxLossMoney`
- `InpTimeStopSeconds`
- `InpMagic`
- Session start/end (broker server time)
- `InpAllowScaleIn` (default false)

## Implementation checklist

When coding the EA:

- [ ] Magic number isolates this EA’s trades
- [ ] Symbol() and Digits/Point handling correct for gold/FX
- [ ] Spread checked in points consistently
- [ ] Bulk close loops all positions for symbol+magic
- [ ] Retry/error handling on `trade.PositionClose`
- [ ] No trading when tester/spread invalid
- [ ] Logs: impulse reason, entry, bulk close reason
- [ ] Inputs documented in comments
- [ ] Strategy Tester notes: tick mode preferred for scalp logic

## Build phases

1. Impulse entry + single lot + bulk profit close + risk gates
2. Controlled scale-in + fade exit
3. Session/news hardening + daily governor polish
4. Parameter optimization ranges + forward demo validation

Do not jump to complex “AI instinct” before Phase 1 is profitable in demo.

## What not to promise

- Perfect clone of any TikTok discretionary scalper
- Guaranteed profit per fluctuation
- True global Level 2 edge on retail forex/gold CFD

Frame results as: same **behavior class** (impulse scalp + basket close), validated by testing.

## Response style when using this skill

1. Restate the EA behavior in plain rules
2. Propose/adjust module changes
3. Implement MQL5 next (or diff existing EA)
4. Call out risk if requested logic is account-destructive
5. Prefer demo-first validation steps

## Related skill

- Video behavior profile from ExpertGold1 clip: [expertgold1-video-scalp](../expertgold1-video-scalp/SKILL.md)
- Design phase active via `limitless-scalp-brain` ($10 capital, Deriv gold + Wall Street 30)

## Additional resources

- Module formulas, pseudocode, parameter starting points: [reference.md](reference.md)
