---
name: expertgold1-video-scalp
description: Reverse-engineer ExpertGold1 TikTok gold scalping behavior into MT5 EA rules from observed video evidence (layered XAUUSD entries, fluctuation scalping, MT5 bulk close). Use when the user mentions ExpertGold1, expertgold1 TikTok, gold live scalp clone, layered sell/buy stacking, bulk close profitable positions, or building an EA like that video style.
---

# ExpertGold1 Video Scalp Behavior

## Source analyzed

- Short link: `https://vt.tiktok.com/ZS4nAmwLw/`
- Resolved: `@expertgold1` / GOLD EXPERT
- Video id: `7672038352341781781`
- Duration: ~51s
- Caption: hashtags only (`#forextrading` …) — no written strategy
- Audio: music bed (no usable trade commentary)

**Status:** video behavior profile locked. Active design skill: `limitless-scalp-brain` ($10 MM + Deriv Wall Street 30 + gold).

## Observed behavior (from frames)

### Setup
- Platform: **MT5 mobile**
- Symbol: **XAUUSDm**
- Chart TF shown: **M5**
- One-click panel lot: **1.00**
- No visible classic indicators on chart (price-action / discretionary look)

### Market context in clip
- Huge bullish spike candle (~4308 → ~4360+)
- Then sharp pullback / chop around ~4346–4351
- Trader scalps the **post-spike fluctuations**, not the full spike ride only

### Entry style
- Opens **many same-direction positions** quickly
- Each position ≈ **1.00 lot**
- Entries clustered in a tight price band (layer / stack)
- Direction flips by session in the clip:
  - stacked **SELL** into weakness / after rejection
  - stacked **BUY** into bounce
- Looks like: feel the micro move → mash same side repeatedly

### Exit style (matches user goal)
- Uses MT5 **Bulk Operations** menu:
  - Close All Positions
  - **Close Profitable Positions**
- Behavior target for EA: when basket is green enough → **bulk close**

### Risk reality shown in same video
- Also shows deep floating loss / near margin stress (negative free margin, ~98% margin level)
- Same style that prints big floating profit can also dump hard
- Treat as **high-risk discretionary aggression**, not a safe template to copy 1:1 with 1.00 lots

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
