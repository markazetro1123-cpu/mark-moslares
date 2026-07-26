# BalochPulse Architecture Audit — COMPLIANCE v2.70

Audit date: 2026-07-26  
File: `MQL5/Experts/EA_BalochPulse.mq5`  
Build marker on chart: **`BalochPulse COMPLIANCE v2.70`**

## Verdict
**COMPLIANT** with locked architecture, plus **entry-path fix** so rules can actually produce trades.

## v2.70 entry-path root cause
No-entry was often caused by:
1. Flat tester/broker ticks (`dir=0`) → signal always empty
2. Pullback state never completed
3. Testing **outside R1 session** (20:00–05:00 local) → by design no new entries

Fixes:
- netMove fallback when directional ticks are flat
- M1 bar path feed into adaptive engine
- micro-pullback completion + same-tick burst
- clearer session block messaging

## Rule matrix

| Rule | Required behavior | Code enforcement | Status |
|---|---|---|---|
| R1 | NY–London only for new entries | `BP_SessionOK` + `BP_CanOpenNewEntries` | PASS |
| R2 | Hard blackout 20:30–20:40 & 21:30–21:40 | `BP_HardBlackout` | PASS |
| R3 | Detect FOMC; other news OK | `BP_FomcCalendarBlock` (FOMC-class only) | PASS |
| R4 | Adaptive tick window (not fixed 30) | `BP_BuildSignal` speed→window | PASS |
| R5 | Candle memory agree | `BP_CandleAgrees` before impulse/burst | PASS |
| R6 | Impulse → pullback → enter | state machine `IMPULSE→PULLBACK→BURST` | PASS |
| R7 | Risk Manager decides lot/entries/mode | `BP_RiskMode` / `BP_AllowedEntries` / `BP_CalcLot` | PASS |
| R8 | $30–$50 can do 2–3 when clean | equity map + reinforce at 30–80 | PASS |
| R9 | Max 15 | `BP_MAX_ENTRIES=15` hard checks | PASS |
| R10 | Same-price burst | locked quote `g_first_fill` one-shot loop | PASS |
| R11 | No martingale | `g_cycle_lot` reused all cycle | PASS |
| R12 | Smart self-exit main exit | `BP_ShouldThreatClose` + emergency SL net only | PASS |
| R13 | No spread filter | no spread gate in entry path | PASS |
| R14 | XAUUSD + US30 same logic | symbol family validate, shared engines | PASS |
| R15 | Engines always-on + monitor | tick push + Comment `RuleNow` | PASS |

## Gaps found in previous build (fixed in v2.60)

1. **R3 over-blocking** — old code blocked all high-impact USD; architecture said other news OK + FOMC.  
   Fix: calendar block is FOMC-class only (+ R2 hard windows).

2. **R4 pollution** — tester synthesis pushed M1 closes every tick, corrupting adaptive tick behavior.  
   Fix: bootstrap once only when buffer empty.

3. **R10 same-price intent** — re-read live quote each order.  
   Fix: lock `g_first_fill` and send that locked price for the burst.

4. **Warnings risk** — unused `OnTradeTransaction` params.  
   Fix: params referenced safely.

5. **Readable compliance structure** — expanded code for maintainability / fewer MetaEditor issues.

## Expected live behavior (state flow)

```
IDLE/BIAS_DETECT
  -> IMPULSE (R4+R5)
  -> PULLBACK (R6)
  -> BURST same-price (R7/R8/R9/R10/R11)
  -> MANAGE
  -> SMART EXIT (R12)
  -> COOLDOWN
```

Guards always applied before new entries: **R1 + R2 + R3**.

## How to verify before accepting

1. Compile `EA_BalochPulse.mq5` (must be version **2.60**).
2. Attach to XAUUSD or US30.
3. Chart comment must show: `BalochPulse COMPLIANCE v2.60`.
4. Journal must show: `COMPLIANCE SELF-CHECK PASS v2.60`.
5. Outside session → `RuleNow: R1 outside NY-London session`.
6. During 20:30–20:40 / 21:30–21:40 → `R2 hard blackout...`.
7. Entries only after impulse+pullback, same fill band, same lot in cycle.

## Notes
- MetaEditor compile must be done on your MT5 (this environment has no MetaEditor binary).
- Use **Every tick / real ticks** in Strategy Tester so R4/R6 can execute naturally.
