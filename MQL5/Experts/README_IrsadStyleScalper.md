# EA_IrsadStyleScalper — Full Irsad copy (XAUUSD)

```
MQL5/Experts/EA_IrsadStyleScalper.mq5
```

## Strategy (full Irsad-style)
1. Bias from candle open (below=SELL priority, above=BUY priority)
2. Buffer arming before pending
3. BuyStop above / SellStop below
4. One-way trail: BUY pending down-only, SELL pending up-only
5. Counter pending ON + flip ON
6. Max 1 position (newest wins on flip)
7. Secure profit then trail
8. Aggressive lot growth with capital
9. Any attached timeframe

## Defaults
- Buffer `1.0`, Offset `0.2`
- Secure `0.30`, Trail `0.15`
- Counter + Flip = **true**
- Session filter = **false** (pure Irsad all-day). Optional PH 8PM–5AM available in Inputs.

## Install
Copy one file → Compile → attach XAUUSD any TF → Algo Trading ON.
