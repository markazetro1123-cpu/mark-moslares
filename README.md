# CandleBiasScalper v2.11 — MT5 EA (single file)

Isang file lang:

```
MQL5/Experts/EA_CandleBiasScalper.mq5
```

## Strategies (ON/OFF sa Inputs)

| Input | Default | Meaning |
|---|---|---|
| `InpStratCandleColor` | `true` | **[1] Candle Color** — GREEN = BUY only, RED = SELL only |
| `InpStratOpposite` | `false` | **[2] Opposite Entry** — DOWN = BUY pending, UP = SELL pending |

Test A/B: i-on ang isa, i-off ang isa.

## Distances (fixed price — no ATR)

| Input | Default |
|---|---|
| `InpBufferDistance` | `1.0` |
| `InpPendingOffset` | `0.2` |
| `InpSecureProfit` | `0.2` |
| `InpTrailDistance` | `0.1` |
| `InpEmergencyStopDist` | `5.0` |

## Install

1. Copy `EA_CandleBiasScalper.mq5` → MT5 `MQL5/Experts/`
2. MetaEditor → Compile (F7)
3. Attach sa XAUUSD / US30 chart
4. Enable Algo Trading

## Disclaimer

Trading is risky. Demo/Strategy Tester first. Not financial advice.
