# CandleBiasScalper v2.10 — MT5 EA (single file)

Isang file lang:

```
MQL5/Experts/EA_CandleBiasScalper.mq5
```

## Strategies (ON/OFF sa Inputs)

Makikita mo sa Inputs ang:

| Input | Default | Meaning |
|---|---|---|
| `InpStratCandleColor` | `true` | **[1] Candle Color** — GREEN candle = BUY only, RED candle = SELL only |
| `InpStratOpposite` | `false` | **[2] Opposite Entry** — DOWN move = BUY pending, UP move = SELL pending |

Paano mag-test kung alin ang profitable:

1. **Test A:** `InpStratCandleColor=true`, `InpStratOpposite=false`
2. **Test B:** `InpStratCandleColor=false`, `InpStratOpposite=true`
3. **Test C (optional):** parehong `true`

Dapat may **isa man lang** na `true` (kung parehong `false`, hindi mag-load ang EA).

## Install

1. Copy `EA_CandleBiasScalper.mq5` → MT5 `MQL5/Experts/`
2. MetaEditor → Compile (F7)
3. Attach sa XAUUSD / US30 chart
4. Enable Algo Trading

## Shared logic

- Buffer arming + BuyStop/SellStop one-way trail
- ATR distances, spread filter, cooldown
- Secure then trail, smart risk defaults

## Disclaimer

Trading is risky. Demo/Strategy Tester first. Not financial advice.
