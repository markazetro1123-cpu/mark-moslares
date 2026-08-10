# Impulse Scalp EA — Reference

## 1) ImpulseDetector formulas

### ATR expansion

```text
atr = ATR(InpATRPeriod) on M1
range = high - low of current or just-closed micro bar
OR displacement = abs(close - open) over lookback window

impulse_range = range >= InpATRMult * atr
```

Starting points (XAUUSD M1):

| Input | Start | Notes |
|------|-------|-------|
| `InpATRPeriod` | 14 | Stable baseline |
| `InpATRMult` | 1.2 – 2.0 | Lower = more trades, more noise |

### Tick velocity

```text
velocity = abs(Bid_now - Bid_N_seconds_ago) / Point
impulse_velocity = velocity >= InpVelocityPoints
```

Starting points:

| Input | Start |
|------|-------|
| `InpVelocitySeconds` | 1 – 3 |
| `InpVelocityPoints` | symbol-dependent (tune on gold) |

### Volume surge

```text
vol_avg = SMA(tick_volume, 20)
impulse_volume = tick_volume >= InpVolumeMult * vol_avg
```

Start: `InpVolumeMult = 1.3 – 1.8`

### Direction from impulse

```text
if close > open and close near high -> bullish
if close < open and close near low  -> bearish
else use signed velocity (up/down)
```

Body strength gate (optional):

```text
body = abs(close - open)
impulse_body = body >= 0.55 * range
```

### Composite score

Require at least:

- range OR velocity true
- AND volume true (or soft-weight)
- AND spread OK
- AND direction unambiguous

## 2) RiskGovernor

Block new entries when any is true:

```text
spread_points > InpMaxSpread
outside session window
news blackout active
daily_loss <= -InpDailyLossLimit
trades_today >= InpMaxTradesDay
open_layers >= InpMaxLayers
existing opposite basket open (default: no hedge)
```

Spread: compute in points consistently for 2/3/5-digit symbols and gold.

## 3) EntryEngine

### Phase 1 — single shot

```text
if impulse.active and layers == 0:
    lot = computeLot()
    open market order in impulse.direction
```

Lot sizing:

```text
fixed: InpLot
or risk: lot ~= risk_money / (sl_distance_value)
```

If using risk-% without hard SL per trade, still enforce basket max loss.

### Phase 2 — scale-in

Allow add only if:

```text
InpAllowScaleIn == true
layers < InpMaxLayers
same direction impulse still active
floating_profit > -InpAddMaxAdverseMoney
seconds since last entry >= InpMinSecondsBetweenEntries
```

Never multiply lot after losses (anti-martingale default).

## 4) BasketManager

Track:

- count of open positions (symbol + magic)
- net lots
- floating profit money
- floating profit points (weighted or average entry vs Bid/Ask)
- oldest position age

Helpers:

```text
GetBasketProfitMoney()
GetBasketProfitPoints()
CountLayers()
CloseAllBasket(reason)
```

## 5) BulkCloseManager

Close all when first matching rule hits:

| Priority | Condition | Reason tag |
|---------|-----------|------------|
| 1 | profit_money >= `InpBasketProfitMoney` | PROFIT_MONEY |
| 2 | profit_points >= `InpBasketProfitPoints` | PROFIT_POINTS |
| 3 | profit_money <= -`InpBasketMaxLossMoney` | BASKET_SL |
| 4 | impulse faded AND profit_money >= `InpMinFadeProfit` | FADE_EXIT |
| 5 | oldest age >= `InpTimeStopSeconds` | TIME_STOP |

Fade heuristic examples:

- velocity collapses below threshold
- opposite rejection wick forms on M1
- price fails to make new micro extreme after entry

## 6) Suggested input defaults (XAUUSD starting template)

Tune per broker digits/contract:

```text
InpLot = 0.01
InpRiskPercent = 0.3
InpATRPeriod = 14
InpATRMult = 1.5
InpVelocitySeconds = 2
InpVelocityPoints = 80   // retune live
InpVolumeMult = 1.5
InpMaxSpread = 35        // points; retune
InpMaxLayers = 1         // Phase 1
InpAllowScaleIn = false
InpBasketProfitMoney = 2.0
InpBasketProfitPoints = 150
InpBasketMaxLossMoney = 5.0
InpMinFadeProfit = 0.5
InpTimeStopSeconds = 180
InpMaxTradesDay = 30
InpDailyLossLimit = 20.0
```

Money targets scale with lot size — document that clearly in EA comments.

## 7) MQL5 structure sketch

```text
Expert/
  OnInit -> validate inputs, symbol specs
  OnDeinit
  OnTick -> RiskGovernor -> Detect -> Enter -> Manage/Close
  OnTradeTransaction (optional fill logs)

Include helpers:
  ImpulseDetect()
  SpreadPoints()
  SessionAllowed()
  BasketProfitMoney()
  CloseAllByMagic()
```

Use `CTrade` with filling mode compatible with broker (`SYMBOL_FILLING_MODE`).

## 8) Tester notes

- Prefer **Every tick based on real ticks** when available
- Spread modeling matters for scalp viability
- Optimize sparingly; walk-forward / demo forward-test after
- If velocity logic depends on wall-clock ticks, verify tester behavior vs live

## 9) Mapping “human instinct” → engines

| Scalper feel | Engine |
|--------------|--------|
| May galaw / spike | ATR + velocity |
| Sama na sa move | direction + market entry |
| Dagdag konti | capped scale-in |
| Okay na tubo, close lahat | bulk profit close |
| Weak na / ayoko na | fade + time-stop |
| Pangit market | spread/session/news/daily governor |

## 10) Anti-patterns

- Entering every wick without displacement threshold
- Opposite hedging to “fix” impulse
- Unlimited layers on drawdown
- Relying on TikTok visual timing without coded gates
- Promising profit on every fluctuation
