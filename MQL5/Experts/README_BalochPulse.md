# EA_BalochPulse — COMPLIANCE v2.60

```
MQL5/Experts/EA_BalochPulse.mq5
```

Audit report:

```
MQL5/Experts/AUDIT_BalochPulse.md
```

## Accept only if
1. Chart shows `BalochPulse COMPLIANCE v2.60`
2. Journal shows `COMPLIANCE SELF-CHECK PASS v2.60`
3. Behavior follows R1–R15 in the audit matrix

## Locked behavior
Impulse → pullback → same-price burst → Risk Manager sizing/count → smart self-exit  
Session NY–London + hard blackouts + FOMC detect  
No spread filter, no martingale, max 15, $30–$50 can open 2–3 when clean  
XAUUSD + US30 same logic

## Inputs (minimal)
Magic / Risk% / lot caps / slippage / buy-sell / session clock / logs
