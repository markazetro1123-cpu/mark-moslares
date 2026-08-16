# EA_CandleRideScalper v1.10

Aggressive candle-follow scalper para sa **XAUUSD / GOLD** at **US30 / Wall Street 30**.

Walang trailing stop. Walang grid.

## Cycle

1. **Green** vs candle open → **BUY only** (stack sa current price)
2. **Red** vs candle open → **SELL only**
3. Nahit ang **lock 0.2** → close, **cooldown 1 candle**, tapos bagong cycle
4. Hindi na-lock, tapos nag-flip ang kulay → close ang old side, open ang new side
5. **Unang tick ng next candle** → auto-close lahat ng leftover, reset, **pwede nang mag-entry** sa bagong candle (maliban kung cooldown o news)

## Lot / entries (equity milestone, max 10 lot)

Tataas lang sa **simula ng cycle**, hindi habang may open trade, hindi per win.

| Equity | Lot | Entries |
|---|---|---|
| $10–$24 | 0.01 | 2 |
| $25–$49 | 0.02 | 3 |
| $50–$99 | 0.03 | 5 |
| $100–$199 | 0.05 | 7 |
| $200–$399 | 0.10 | 10 |
| $400–$799 | 0.20 | 13 |
| $800–$1,499 | 0.40 | 16 |
| $1,500–$2,999 | 0.80 | 18 |
| $3,000–$4,999 | 1.50 | 20 |
| $5,000–$9,999 | 3.00 | 20 |
| $10,000–$19,999 | 6.00 | 20 |
| $20,000+ | **10.00 max** | 20 |

## News filter

Bawal mag-trade sa US high-impact:

- CPI
- NFP / Non-Farm Payrolls
- Unemployment
- Interest rate / FOMC / rate decision

Entry **10 minuto after** ang news. Default: i-flatten ang open trades pag nagsimula ang news window.

Ginagamit ang MT5 Economic Calendar (US/USD, high importance). Fallback: first Friday 08:30 New York = NFP.

## Install

1. Copy `EA_CandleRideScalper.mq5` sa `MQL5/Experts/`
2. Compile sa MetaEditor
3. Attach sa XAUUSD o Wall Street 30 (M1 o M5)
4. Load `CandleRide_XAUUSD.set` o `CandleRide_US30.set`
5. Enable Algo Trading

Demo muna. Hindi guarantee ng tubo.
