---
name: scalp-replication-audit
description: Audits claims and requirements for replicating a video scalper in an MT5 EA. Use when the user asks for a 100% clone, trader instinct, guaranteed profitability, micro-spike behavior, pre-code strategy audit, or deciding what engines to include or exclude.
---

# Scalper Replication Audit

## Required sources

Read:

1. `docs/REPLICATION_AUDIT.md`
2. `docs/FINAL_BEHAVIOR_SPEC.md`
3. `expertgold1-video-scalp` skill for observed clip evidence
4. `limitless-scalp-brain` skill for the approved Phase 1 brain

## Core distinction

Always separate these targets:

- **Specification fidelity:** every approved deterministic rule behaves exactly
  as written. This can target 100%.
- **Observable behavior fidelity:** impulse entry, capped same-side stacking, and
  whole-basket profit close resemble the clip.
- **Profit fidelity:** identical profits, win rate, or future decisions. This
  cannot be inferred or guaranteed from a highlight video.

Do not allow the phrase “100% clone” to erase that distinction.

## Audit workflow

### 1. Build the evidence table

For each claimed behavior mark:

- `OBSERVED`: directly visible/measurable;
- `INFERRED`: plausible but not proven;
- `UNKNOWN`: absent from evidence;
- `OUR_RULE`: deliberate design/safety choice.

Never promote inferred/unknown behavior to observed.

### 2. Inventory missing data

Request or note absence of:

- unedited recordings including losing sequences;
- exported MT5 trade history;
- entry/exit timestamps;
- broker contract/leverage/account details;
- raw ticks/spreads for the same periods;
- exact stop, session, news, and manual-override rules.

### 3. Audit required engines

Confirm the design includes:

1. SymbolCapability
2. TickWindow
3. CostExecution
4. Regime
5. DirectionConfidence
6. MoneyManager/RiskGovernor
7. BasketManager/BulkClose
8. Cooldown/AntiChurn
9. Telemetry/Replay

### 4. Audit exclusions

Keep disabled until evidence supports them:

- post-spike fade in Phase 1;
- martingale/grid/recovery;
- adding to losing baskets;
- Level 2 dependence for CFDs;
- ML/“AI instinct” without labeled data;
- multi-layer spam on $10;
- fixed point thresholds shared across Gold and Wall Street 30.

### 5. Define testable acceptance

Require:

- reason codes for every enter/skip/add/close;
- deterministic tick replay;
- simulated spread/slippage and close failures;
- out-of-sample testing with fixed parameters;
- separate Deriv demo validation per symbol;
- positive expectancy after costs before calling a configuration profitable.

## Decision output template

```markdown
## Replication decision

- Observed behaviors locked: [...]
- Inferences still unproven: [...]
- Required engines: [...]
- Features disabled: [...]
- Missing evidence: [...]
- Ready to code: yes/no
- Blocking reason: [...]
```

## Rule for implementation requests

If the pre-code gate is not approved, improve the specification or ask for the
missing choice—do not generate a “full version” EA. If approved, implement Phase
1 only and validate each module before adding optional behavior.
