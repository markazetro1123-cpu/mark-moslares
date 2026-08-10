---
name: limitless-scalp-brain
description: Design the Limitless Scalp EA brain/mindset, $10-capital money management, and Deriv multi-symbol impulse scalping (XAUUSD + Wall Street 30). Use when designing or coding this EA, discussing EA utak/mindset, sureball entries, aggressive discipline, lot sizing for small capital, Deriv US30/Wall Street 30, or starting the Phase 1 build.
---

# Limitless Scalp EA Brain

## Frozen Phase 1 contract

Read and follow [`docs/FINAL_BEHAVIOR_SPEC.md`](../../../docs/FINAL_BEHAVIOR_SPEC.md)
before designing or coding. The clip does not prove a hidden entry formula or
that every micro-spike is profitable. Copy the observed behavior class, then
apply the finalized measurable rules.

## User mindset (verbatim)

mag eenter sya ng trade scalping sureball entry dapat meron syang malakas na instinc sa bawat price movement kung may price movement pataas daoat makakasabay sya at makakapag scalp pero dapat siguraduhin nyarin na ayun talaga ang direction.. isapa sa dapat na mindset nya is isa syang limitless ang mindset nya is to win.. at meron syang agrresive disipline nadapat sa bawat price movement iisipin ng ea na dapat kumita ako sa bawat movement nito dapat makapag scalp ako.. at dilang sya pang xauusd dapat pwede rin sya sa us 30.. deriv ang broker ko so ang symbol nun is wall street 30

## What “Limitless” means in code

- **Limitless hunting of valid impulses** under risk caps — not unlimited lots/layers
- Aggressive discipline = enter only when direction confirmed, then manage hard
- “Sureball” = high-conviction filter stack, not a profit guarantee
- Win mindset = persist across many small basket targets; cut losers via basket SL / daily kill
- Observe every movement; trade only those whose expected travel exceeds noise and costs

## Strategy to clone (from video) + our fixes

Keep behavior class from ExpertGold1 clip:

1. React to price movement / post-impulse fluctuations
2. Enter with confirmed direction (stack same side, capped)
3. Bulk close when profitable

Fix what the video does unsafely:

- Lot sizing from equity (start **$10**)
- Few entries when capital is small
- Hard money management + margin abort
- Close the full EA basket rather than orphaning losing positions

Related skills: `expertgold1-video-scalp`, `impulse-scalp-ea`.

## Brain loop (mindset → modules)

```text
every tick:
  update rolling 1s/3s/10s tick windows
  RiskGovernor / MoneyManager gates
  impulse = qualify displacement + velocity + efficiency + spread ratio
  direction_score = velocity + efficiency + break + persistence + context
  if impulse && direction_score >= 75 && canAffordMinimumLot:
      enter once           // "sumama sa taas/baba"
  if score >= 80 && basket_not_losing && layer_policy_allows:
      capped add
  if basket_profit >= target:
      bulk close           // "pag profit close na"
  if opposite impulse / fade / basket loss / margin danger / time-stop:
      emergency bulk close
  cooldown the movement ID
```

## Direction confirmation (“siguraduhin ang direction”)

Use a 0–100 score. Phase 1 requires **≥75**:

- signed tick velocity (25)
- displacement vs spread/volatility (20)
- directional efficiency (20)
- micro high/low break (15)
- tick persistence (10)
- M1/M5 context (10)

Reject/penalize spread shock, stale ticks, opposite rejection, or failed break.
Phase 1 follows continuation only. A post-spike fade requires a later separate
exhaustion engine and stays disabled.

## Money management for $10 start

See [reference.md](reference.md) for formulas.

Defaults:

| Knob | $10 start |
|------|-----------|
| Basket risk ceiling | 2% equity |
| Lot | calculated then normalized; skip if broker minimum is too large |
| Max layers | 1 below $20 equity |
| Basket profit | adaptive target after estimated costs |
| Basket max loss | hard cap < daily loss |
| Daily loss kill | 5% equity or 3 consecutive basket losses |
| Martingale | OFF |

The engine may add a second layer only after equity policy permits it, the first
position is not losing, and continuation score remains ≥80. Never force minimum
lot when its stop risk exceeds the budget.

## Symbols (Deriv)

- Configurable `InpSymbol` / trade current chart `_Symbol`
- Profiles:
  - Gold: `XAUUSD` / broker gold alias
  - US30: **Wall Street 30** (confirm exact Deriv Market Watch name in OnInit)
- Per-symbol inputs: max spread, ATR mult, velocity points (US30 ≠ gold)

## Build order

1. Freeze/approve behavior specification (current phase)
2. MoneyManager + RiskGovernor ($10 affordability and margin gates)
3. TickWindow + continuation ImpulseDetector + 75-point DirectionFilter
4. EntryEngine (one layer by default)
5. whole-basket BulkCloseManager + cooldown/lockout
6. symbol-normalized Gold + Wall Street 30 profiles
7. tick replay, Strategy Tester, then Deriv demo

## Agent behavior

- Design/code toward this brain; cite modules by name
- Do not silently broaden Phase 1 into fade, martingale, or multi-layer spam
- Warn if user asks for 1.00 lots, unbounded stacks, or martingale on $10
- Prefer demo validation steps after each phase
