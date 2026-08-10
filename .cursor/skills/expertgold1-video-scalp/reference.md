# ExpertGold1 video — frame notes

Video: `@expertgold1` `7672038352341781781` (~51s)

Numbers below are approximate from sampled frames (2 fps extract). Broker symbol `XAUUSDm`; quote scale may be broker-specific.

## Timeline highlights

| Phase | What is on screen | Behavior signal |
|------|-------------------|-----------------|
| Open | Chart M5 XAUUSDm, lot=1 panel | Watching post-spike gold |
| Early trade tab | Multiple SELL 1.00, floating profit hundreds | Stacked shorts + ready to bulk close |
| Bulk menu | “Bulk Operations”: Close All / Close Profitable | Explicit exit mechanic |
| Mid | More SELL layers ~4349–4350, profits ~$165–$200 each | Tight cluster scaling |
| Chart mid | SELL line(s) after huge green spike + red pullback | Trading the fluctuation after spike |
| Stress frame | Many SELL 1.00 underwater; free margin negative; ~98% margin | Same style can blow margin |
| Later buy stack | Many BUY 1.00 ~4347.6–4348.0; floating +$4.5k class | Direction flip + stack again |
| Late sell stack | Many SELL 1.00; floating +$17k class on larger equity | Aggressive stack into drop |

## Concrete observed patterns

### A) Stack density
- Multiple positions, same symbol, same side
- Entry prices often within ~0.3–1.0 gold points of each other
- Fixed **1.00 lot** each click

### B) Profit capture style
- Holds basket while micro move runs
- Uses MT5 bulk close UI (especially profitable close)
- Matches user intent: **pag nag-profit, close na (lahat)**

### C) Chart context
- Giant impulse candle precedes active scalping window
- Active work happens in the chop/retrace after the impulse
- M5 is viewing TF; execution speed implies tick/manual mash, not slow indicator lag

### D) Risk fingerprints
- High notional vs equity (1.00 lot × many layers on gold)
- Floating PnL swings from large green to large red in same style
- Margin level can collapse quickly when stacked wrong-way

## EA parameter mapping (safer clone)

Do **not** default to video lots. Suggested starting translation:

```text
Symbol = XAUUSD / XAUUSDm
DetectTF = M1 (context M5 optional)
LotMode = risk percent (e.g. 0.25%–0.5% per layer)
MaxLayers = 3
MinSecondsBetweenEntries = 1–3
BasketProfitMoney = tune to account (demo first)
BasketProfitPoints = small gold move target
BasketMaxLossMoney = hard stop for whole basket
MarginAbortLevel = e.g. < 150% -> close all / block new
AllowHedge = false
AllowMartingale = false
```

## Mode recipes

### Momentum stack (primary)
```text
if micro_velocity aligned and spread_ok:
  open/add same direction until MaxLayers
if basket_profit >= target: CloseAll
```

### Post-spike fade (secondary)
```text
if M5/M1 range >= SpikeATRMult * ATR
and rejection / opposite velocity appears:
  stack fade direction with tighter MaxLayers
if basket_profit >= target: CloseAll
else if adverse >= max: CloseAll
```

## What the video does NOT prove

- Sustainable edge (clip is highlight / live flex)
- Indicator set (none visible)
- Stop-loss discipline (not shown clearly)
- That phone-only EA execution is possible (MT5 mobile cannot run EAs; desktop/VPS still required)

## Implementation note for later

When user says build now:
1. Load this skill + `impulse-scalp-ea`
2. Ship Phase 1: impulse detect + single/limited stack + bulk profit close
3. Demo on XAUUSD with tiny lots before any 1.00-lot fantasy settings
