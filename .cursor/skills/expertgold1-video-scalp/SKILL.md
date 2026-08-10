---
name: expertgold1-video-scalp
description: Reverse-engineer ExpertGold1 TikTok gold scalping behavior into MT5 EA rules from observed video evidence (layered XAUUSD entries, fluctuation scalping, MT5 bulk close). Use when the user mentions ExpertGold1, expertgold1 TikTok, gold live scalp clone, layered sell/buy stacking, bulk close profitable positions, or building an EA like that video style.
---

# ExpertGold1 Video Scalp Behavior

## Sources analyzed

Primary + five follow-up links (four unique videos; one duplicate):

| Link | Video ID | Notes |
| --- | --- | --- |
| `https://vt.tiktok.com/ZS4nAmwLw/` | `7672038352341781781` | Original ~51s profile |
| `https://vt.tiktok.com/ZS4nm6uRX/` | `7670930749335358741` | Same as next link |
| `https://vt.tiktok.com/ZS4nmmHke/` | `7670930749335358741` | Duplicate |
| `https://vt.tiktok.com/ZS4nmhsx9/` | `7670199496508263700` | SELL stack + Bulk Ops |
| `https://vt.tiktok.com/ZS4nmvSTH/` | `7668344923409796373` | BUY then SELL flip |
| `https://vt.tiktok.com/ZS4nmCHPx/` | `7660174167156739349` | 1.60-lot momentum SELL |

Frame matrix: `docs/VIDEO_EVIDENCE_MATRIX.md`.

**Status:** multi-video behavior profile locked. Active design skill: `limitless-scalp-brain` ($10 MM + Deriv Wall Street 30 + gold).

## Observed behavior (from frames)

### Setup
- Platform: **MT5 mobile**
- Symbol: **XAUUSDm**
- Chart TF shown: **M1 / M5 / M15** (highlights often M15)
- One-click panel lots: **1.00**, **1.60**, or **2.00** (fixed within a basket)
- No visible classic indicators on chart (naked price / discretionary mash)

### Entry trigger class (confirmed)
- **Price-movement / impulse mash** — rapid one-click SELL/BUY during live candle fluctuation
- Not an indicator crossover, not a disclosed pip-step grid
- Exact human thresholds remain `UNKNOWN`; EA uses deterministic tick windows

### Market context across clips
- Large intra-candle / multi-candle spikes and rejections on gold
- Continuation stacks (SELL into falling move) and inferred post-spike fades both appear
- Trader scalps **active price movement**, not candle-close signals

### Entry style
- Opens **many same-direction positions** quickly
- Entries clustered in a tight price band (layer / stack)
- Direction flips between baskets:
  - stacked **SELL** into weakness / after rejection / with bearish continuation
  - stacked **BUY** into bounce / rebound
- Pattern: feel the micro move → mash same side repeatedly

### Exit style (matches user goal)
- Uses MT5 **Bulk Operations** menu:
  - Close All Positions
  - **Close Profitable Positions**
- Behavior target for EA: when basket is green enough → **bulk close whole basket**
- Not every clip shows the final close (some end while still floating profit)

### Risk reality shown in videos
- Deep floating loss / near margin stress (negative free margin; margin levels ~29–98%)
- Same style that prints big floating profit can also dump hard
- Treat as **high-risk discretionary aggression**, not a safe template to copy 1:1 with 1.00 lots on $10

## Translate video → EA rules

Do not copy lot=1 blindly. Encode the **behavior class** with safer sizing.

| Video action | EA module |
|---|---|
| Post-spike / fast fluctuation | Impulse + micro-momentum detector |
| Mash same side many times | Layered EntryEngine (capped) |
| Same direction cluster | BasketManager (one side at a time) |
| Bulk Operations → close profitable | BulkCloseManager on basket $ / points |
| Manual chart watching M5 | Detect on M1 ticks; optional M5 context |

## Default EA behavior to implement later

```text
1) Detect impulse / active fluctuation (ATR + velocity + volume)
2) Choose side from current micro direction (or fade after exhaustion — see modes)
3) Open first market order
4) Scale-in same side while impulse continues (max layers hard-capped)
5) If basket floating profit >= target -> CloseAll (bulk)
6) If basket loss / margin danger -> emergency CloseAll
7) No opposite hedge by default
```

### Two modes observed / supported

1. **Momentum stack** — add with the active micro move (BUY stack up / SELL stack down)
2. **Post-spike fade** — after extreme expansion candle, fade retrace with stacked entries

Start build with mode 1 + bulk profit close. Add mode 2 only with exhaustion filters.

## Hard safety overrides (required if cloning this style)

- Default lot from risk %, not 1.00
- `MaxLayers` hard cap (start 2–4)
- `BasketProfitMoney` / `BasketProfitPoints` bulk close
- `BasketMaxLossMoney` + margin-level abort
- Spread gate + session/news filter
- Daily loss kill switch
- No martingale lot multiplier

If user asks to mirror video lots/stack depth exactly, warn and require explicit opt-in.

## Relationship to other skill

- Build mechanics / module checklist: use [impulse-scalp-ea](../impulse-scalp-ea/SKILL.md)
- This skill = **video evidence + target behavior profile**
- When implementing: apply both (profile from here, architecture from impulse-scalp-ea)

## Agent workflow when this skill is active

1. Restate observed video behavior in plain rules
2. Map requested feature to Entry / Basket / BulkClose / RiskGovernor
3. Prefer safer defaults than the video’s 1-lot spam
4. Implement MQL5 only when user asks to build (they said use suggestions later)
5. Keep demo-first validation steps

## Additional resources

- Frame-level notes, numbers, and risk examples: [reference.md](reference.md)
