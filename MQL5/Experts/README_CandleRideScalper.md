# EA_CandleRideScalper v1.00

Aggressive candle-follow scalper para sa **XAUUSD / GOLD** at **US30 / Wall Street 30**.

Mindset: **kada galaw ng candle, sumabay**. Green = buy, red = sell. Konting profit, i-lock, auto-close. Walang trailing stop. Walang grid.

## Logic

Current candle vs **OPEN PRICE**:

- Open `4401`, umakyat at naging **green** → **BUY only**
- Open `4401`, bumaba at naging **red** → **SELL only**
- Kung red ang sell, tapos umakyat at naging green → **close sell, BUY**
- Hindi grid. Market entries sa **current price** lang. Puwedeng maraming position sa iisang price (stack).

Buffer mula sa open (default gold `0.10`, US30 `1.0`) para hindi mag-flip sa gitna ng open.

## Auto-close lock (walang trailing)

Example (gold):

1. BUY @ `4401`
2. Umakyat sa `4401.5` (+0.50) → trigger
3. Default **`InpPullbackLock=true`**: naka-arm sa `4401.5`, **auto-close** pag dating sa lock `4401.2` (+0.20). Walang trailing — hindi sinusundan pataas ang lock.
4. Kung `InpPullbackLock=false`: auto-close mismo sa trigger `4401.5`

Defaults:

| | Gold | US30 |
|---|---|---|
| Trigger | 0.50 | 2.0 |
| Lock | 0.20 | 1.0 |
| Pullback lock | true (arm 0.50, close 0.20) | true |

May emergency SL lang para sa spike. Hindi ito trailing.

## Capital → entries at lot

Starting **$10**, lot `0.01`.

| Equity | Entries | Lot (from 0.01) |
|---|---|---|
| $10 | 2 | 0.01 |
| $25 | ~3 | 0.02 |
| $50 | 5 | 0.03 |
| mas mataas | hanggang 20 | lumalaki |

`$10–$50` = **2 hanggang 5** entries. Max **20**.

## Install

1. Copy `EA_CandleRideScalper.mq5` sa `MQL5/Experts/`
2. Compile sa MetaEditor (0 errors, 0 warnings)
3. Attach sa XAUUSD o Wall Street 30 (M1 o M5)
4. Load preset kung gusto
5. Enable Algo Trading

## Presets

- `MQL5/Presets/CandleRide_XAUUSD.set`
- `MQL5/Presets/CandleRide_US30.set`

Demo muna. Hindi guarantee ng tubo.
