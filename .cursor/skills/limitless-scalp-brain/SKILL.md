---
name: limitless-scalp-brain
description: Design the Limitless Scalp EA brain/mindset, $10-capital money management, and Deriv multi-symbol impulse scalping (XAUUSD + Wall Street 30). Use when designing or coding this EA, discussing EA utak/mindset, sureball entries, aggressive discipline, lot sizing for small capital, Deriv US30/Wall Street 30, or starting the Phase 1 build.
---

# Limitless Scalp EA Brain

## User mindset (verbatim)

mag eenter sya ng trade scalping sureball entry dapat meron syang malakas na instinc sa bawat price movement kung may price movement pataas daoat makakasabay sya at makakapag scalp pero dapat siguraduhin nyarin na ayun talaga ang direction.. isapa sa dapat na mindset nya is isa syang limitless ang mindset nya is to win.. at meron syang agrresive disipline nadapat sa bawat price movement iisipin ng ea na dapat kumita ako sa bawat movement nito dapat makapag scalp ako.. at dilang sya pang xauusd dapat pwede rin sya sa us 30.. deriv ang broker ko so ang symbol nun is wall street 30

## What “Limitless” means in code

- **Limitless hunting of valid impulses** under risk caps — not unlimited lots/layers
- Aggressive discipline = enter only when direction confirmed, then manage hard
- “Sureball” = high-conviction filter stack, not a profit guarantee
- Win mindset = persist across many small basket targets; cut losers via basket SL / daily kill

## Strategy to clone (from video) + our fixes

Keep behavior class from ExpertGold1 clip:

1. React to price movement / post-impulse fluctuations
2. Enter with confirmed direction (stack same side, capped)
3. Bulk close when profitable

Fix what the video does unsafely:

- Lot sizing from equity (start **$10**)
- Few entries when capital is small
- Hard money management + margin abort

Related skills: `expertgold1-video-scalp`, `impulse-scalp-ea`.

## Brain loop (mindset → modules)

```text
every tick:
  RiskGovernor / MoneyManager gates
  impulse = detect price movement (ATR + velocity + volume)
  direction = confirm side (body + micro structure; optional M5 context)
  if impulse && direction_confirmed && canAffordLayer:
      enter / capped add   // "sumama sa taas/baba"
  if basket_profit >= target:
      bulk close           // "pag profit close na"
  if basket_loss / margin danger / time-stop:
      emergency bulk close
```

## Direction confirmation (“siguraduhin ang direction”)

Require ≥2 aligned signals before entry:

- Signed tick velocity up/down
- Candle body closes near extreme of move
- Optional: break of micro swing OR EMA micro-slope agree
- Reject if spread shock / opposing wick rejection just printed

Up move → BUY scalp only if confirmation passes.  
Down move → SELL scalp only if confirmation passes.

## Money management for $10 start

See [reference.md](reference.md) for formulas.

Defaults:

| Knob | $10 start |
|------|-----------|
| Risk per layer | 1%–2% equity |
| Lot | broker min lot (often 0.01) after normalize |
| Max layers | 1–2 |
| Basket profit | small $ or points target |
| Basket max loss | hard cap < daily loss |
| Daily loss kill | stop trading for day |
| Martingale | OFF |

As equity grows, MoneyManager may allow slightly larger lot / layers — never jump to video 1.00 on small accounts.

## Symbols (Deriv)

- Configurable `InpSymbol` / trade current chart `_Symbol`
- Profiles:
  - Gold: `XAUUSD` / broker gold alias
  - US30: **Wall Street 30** (confirm exact Deriv Market Watch name in OnInit)
- Per-symbol inputs: max spread, ATR mult, velocity points (US30 ≠ gold)

## Build order

1. MoneyManager + RiskGovernor ($10-safe)
2. ImpulseDetector + DirectionFilter (sureball gates)
3. EntryEngine (1 layer, then optional 2)
4. BulkCloseManager
5. Dual-symbol input profiles (gold + Wall Street 30)
6. Demo on Deriv before live

## Agent behavior

- Design/code toward this brain; cite modules by name
- Warn if user asks for 1.00 lots, unbounded stacks, or martingale on $10
- Prefer demo validation steps after each phase
