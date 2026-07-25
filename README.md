# TrendPulse EA — MetaTrader 5 Trading Bot

Automated **Expert Advisor (EA)** for MetaTrader 5. Strategy: **EMA crossover + RSI filter**, with ATR-based stops and risk-based position sizing.

## Strategy (simple)

1. **BUY** when Fast EMA crosses above Slow EMA and RSI is below the buy-max (not overbought).
2. **SELL** when Fast EMA crosses below Slow EMA and RSI is above the sell-min (not oversold).
3. Stop-loss = ATR × multiplier; take-profit = SL × risk-reward ratio.
4. Optional trailing stop after entry.

Default risk: **1% of balance per trade**.

## Project layout

```
MQL5/
  Experts/EA_TrendPulse.mq5   ← main EA (compile this)
  Include/TradeHelpers.mqh    ← lot sizing, filters, trailing
config/
  TrendPulse_XAUUSD_H1.set    ← sample input preset
```

## Install sa MetaTrader 5

1. Buksan ang MT5 → **File → Open Data Folder**.
2. Copy:
   - `MQL5/Experts/EA_TrendPulse.mq5` → `MQL5/Experts/`
   - `MQL5/Include/TradeHelpers.mqh` → `MQL5/Include/`
3. Sa MetaEditor, open `EA_TrendPulse.mq5` → **Compile** (F7).
4. I-drag ang EA sa chart (hal. XAUUSD H1 o EURUSD H1).
5. I-enable **Algo Trading** sa toolbar.
6. (Optional) Load preset: Inputs → **Load** → `config/TrendPulse_XAUUSD_H1.set`.

## Important inputs

| Input | Default | Meaning |
|-------|---------|---------|
| `InpFastEMA` / `InpSlowEMA` | 12 / 26 | Trend crossover |
| `InpRSIBuyMax` / `InpRSISellMin` | 60 / 40 | RSI entry filter |
| `InpRiskPercent` | 1.0 | % balance risk per trade |
| `InpFixedLots` | 0 | >0 to ignore risk % |
| `InpATRMultiplier` | 1.5 | SL distance |
| `InpRRRatio` | 2.0 | TP = SL × this |
| `InpMaxSpreadPts` | 30 | Skip if spread too wide |
| `InpUseTrailing` | true | Move SL with price |

## Backtest muna (strongly recommended)

1. MT5 → **View → Strategy Tester**.
2. Select `EA_TrendPulse`, symbol, timeframe (H1), model: **Every tick based on real ticks** kung available.
3. Run on **demo** first. Huwag mag-live hangga't hindi ka satisfied sa results.

## Disclaimer

Trading involves risk of loss. This EA is educational / starter tooling — **not financial advice**. Test thoroughly on demo before any real account.
