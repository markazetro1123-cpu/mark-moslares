# mark-moslares — Poverty Scalper Clone (EA)

Transparent, open na re-implementation ng **"Poverty Scalper Robot"** style (yung viral sa TikTok) para sa **MetaTrader 5**. Ginawa para pag-aralan at i-backtest ang strategy — hindi kopya ng kanilang binary.

> ⚠️ **Babala:** Para sa edukasyon at DEMO testing. Ang trading ay may risk. Palaging mag-demo muna bago mag-live. Basahin ang [`docs/STRATEGY_ANALYSIS.md`](docs/STRATEGY_ANALYSIS.md) para sa mga red flag (posibleng martingale, walang verified results, atbp.) ng orihinal.

## Ano ito

Isang **M1 momentum scalper** na ginagaya ang ipinapakitang style ng Poverty Scalper Robot:

- M1 timeframe scalping (majors / XAUUSD / indices)
- Momentum + trend entries (EMA cross + RSI + candle body)
- Fixed Take Profit / Stop Loss kada trade
- Spread filter + trading-session filter (London/NY, Friday cutoff)
- Optional trailing stop
- Max equity drawdown guard
- On-chart live stats panel

Detalyadong breakdown: [`docs/STRATEGY_ANALYSIS.md`](docs/STRATEGY_ANALYSIS.md)

## Files

```
MQL5/Experts/PovertyScalperClone/PovertyScalperClone.mq5   # ang EA
docs/STRATEGY_ANALYSIS.md                                   # strategy analysis
```

## Install (MetaTrader 5)

1. Buksan ang MT5 → **File → Open Data Folder**.
2. Kopyahin ang `PovertyScalperClone.mq5` papunta sa `MQL5/Experts/`.
3. Sa **MetaEditor**, buksan ang file → **Compile** (F7). Dapat 0 errors.
4. Sa MT5, i-refresh ang Navigator → i-drag ang EA sa isang **M1 chart**.
5. I-enable ang **Algo Trading**.

## Backtest (Strategy Tester)

1. **View → Strategy Tester** (Ctrl+R).
2. Expert: `PovertyScalperClone`, Symbol: `EURUSD` (o XAUUSD), Timeframe: **M1**.
3. Modeling: **Every tick based on real ticks**.
4. Piliin ang date range → **Start**.
5. Tingnan ang report + ang on-chart panel.

## Mga importanteng setting

| Input | Default | Description |
|---|---|---|
| `InpLots` | 0.01 | Fixed lot size |
| `InpTakeProfitPts` | 80 | TP sa points |
| `InpStopLossPts` | 80 | SL sa points |
| `InpMaxSpreadPoints` | 30 | Di papasok kung mas malawak (0 = ignore) |
| `InpUseTrailing` | true | Trailing stop on/off |
| `InpEmaFast / InpEmaSlow` | 8 / 21 | Trend direction |
| `InpRsiPeriod` | 14 | Momentum filter |
| `InpMomentumBodyPts` | 30 | Min candle body para pumasok |
| `InpUseSession` | true | London/NY session filter |
| `InpMaxDrawdownPct` | 20 | Hihinto sa bagong trades kapag lumampas |

Para mas "scalper" na pakiramdam: gawing 30/30 ang TP/SL at i-restrict ang session sa London/NY overlap.

## Testing status

Ang code ay nakasulat para sa MT5 (MQL5) at kailangang i-compile/i-backtest sa **MetaTrader 5** (MetaEditor + Strategy Tester) — hindi ito tumatakbo sa Linux server nang walang MT5/Wine. Tingnan ang PR notes para sa verification na ginawa.
