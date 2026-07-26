# mark-moslares — Poverty Scalper Clone (EA)

Transparent, open na re-implementation ng **"Poverty Scalper Robot"** style (viral sa TikTok) para sa **MetaTrader 5 at MetaTrader 4**, kasama ang **Deriv V75** preset. Para pag-aralan at i-backtest ang strategy — hindi kopya ng kanilang binary.

> ⚠️ **Babala:** Para sa edukasyon at DEMO testing. May risk ang trading. Mag-demo/backtest muna bago mag-live. Basahin ang [`docs/STRATEGY_ANALYSIS.md`](docs/STRATEGY_ANALYSIS.md) para sa red flags (posibleng martingale, walang verified results) ng orihinal.

## Ano ito

**M1 momentum scalper** na ginagaya ang style ng Poverty Scalper Robot:

- M1 timeframe scalping (majors / XAUUSD / Deriv synthetics)
- Momentum + trend entries: **EMA(8/21) cross + RSI(14) + candle-body filter**
- **Fixed, tight TP/SL** kada trade (default 30/30 points, ~1:1 RR)
- Spread filter + session filter (default ~London/NY overlap, Friday cutoff)
- Optional trailing stop, broker **stop-level clamping**
- Max equity **drawdown guard**, on-chart live **stats panel**

## Files

```
MQL5/Experts/PovertyScalperClone/PovertyScalperClone.mq5   # MT5 EA (+ Deriv MT5)
MQL5/Presets/MajorsScalper.set                             # MT5 preset: FX majors/XAUUSD
MQL5/Presets/DerivV75.set                                  # MT5 preset: Deriv Volatility 75
MQL4/Experts/PovertyScalperClone/PovertyScalperClone.mq4   # MT4 EA (FX/XAUUSD)
docs/STRATEGY_ANALYSIS.md                                   # strategy analysis + red flags
```

## Install — MetaTrader 5

1. MT5 → **File → Open Data Folder**.
2. Kopyahin ang `PovertyScalperClone.mq5` → `MQL5/Experts/`.
3. (Optional) kopyahin ang `.set` files → `MQL5/Presets/`.
4. **MetaEditor → Compile (F7)**. Dapat 0 errors.
5. I-drag ang EA sa isang **M1 chart**, i-enable ang **Algo Trading**.
6. Sa Inputs tab → **Load** ang tamang preset (`MajorsScalper.set` o `DerivV75.set`).

## Install — MetaTrader 4

1. MT4 → **File → Open Data Folder**.
2. Kopyahin ang `PovertyScalperClone.mq4` → `MQL4/Experts/`.
3. **MetaEditor → Compile (F7)**. Dapat 0 errors.
4. I-drag sa **M1 chart**, i-enable ang **AutoTrading**.

## Deriv V75 (Volatility 75 Index)

Deriv synthetics ay tumatakbo sa **Deriv MT5** (gamitin ang MT5 EA, hindi MT4).

- I-load ang `DerivV75.set`.
- **Session OFF** by default — 24/7 trading ang synthetics (kasama weekends).
- Ang TP/SL/body values sa preset ay **placeholder** — malaki ang point values ng V75. **I-calibrate:** sukatin ang normal na M1 candle body (points) sa Data Window, tapos i-scale ang `InpMomentumBodyPts` at TP/SL (panatilihin ~1:1 RR).

## Backtest (Strategy Tester)

1. **View → Strategy Tester**.
2. Expert: `PovertyScalperClone`, Symbol: `EURUSD`/`XAUUSD` (o `Volatility 75 Index` sa Deriv MT5), Timeframe: **M1**.
3. Modeling: **Every tick based on real ticks**.
4. Piliin ang date range → **Start**. Tingnan ang report + on-chart panel.

## Key settings

| Input | Default | Description |
|---|---|---|
| `InpLots` | 0.01 | Fixed lot size |
| `InpTakeProfitPts` | 30 | TP (points) |
| `InpStopLossPts` | 30 | SL (points) |
| `InpMaxSpreadPoints` | 20 | Skip kung mas malawak (0 = ignore) |
| `InpUseTrailing` | true | Trailing stop |
| `InpEmaFast/Slow` | 8 / 21 | Trend direction |
| `InpRsiPeriod` | 14 | Momentum filter |
| `InpMomentumBodyPts` | 30 | Min candle body para pumasok |
| `InpUseSession` | true | Session filter (server time) |
| `InpSessionStartHour/EndHour` | 13 / 17 | ~London/NY overlap (adjust sa GMT offset) |
| `InpMaxDrawdownPct` | 20 | Hihinto sa bagong trades kapag lumampas |

> Ang TP/SL ay **auto-clamped** sa broker minimum stop distance (`SYMBOL_TRADE_STOPS_LEVEL` / `MODE_STOPLEVEL`), kaya di ma-reject ang sikip na 30-point stops.

## Testing status

Ang MQL5/MQL4 ay kailangang i-compile (MetaEditor F7) at i-backtest sa **MT5/MT4 Strategy Tester** — hindi ito tumatakbo sa Linux CI VM nang walang MT4/MT5 + broker demo login. Ginawa ang static verification (balanced brackets, defined functions, API review). Tingnan ang PR notes.
