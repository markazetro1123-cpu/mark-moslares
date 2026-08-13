# EA_NYSweepHunter v1.00

Bagong MT5 Expert Advisor: **NY liquidity-sweep reversal** para sa **XAUUSD / GOLD** at **US30 / Wall Street 30** (Deriv).

Hindi ito clone ng ColorBurst, OpenColor, Irsad, Impulse, o Limitless. Ang trabaho nito: markahan ang Asian range, hintayin ang sweep ng high/low sa NY, tapos fade ang grab.

## Paano ito kumikita (logic)

1. **Asian range** (default PH 08:00–16:00) = high at low ng session.
2. **NY window** (default PH 20:00–05:00) = trading hours.
3. **Sweep BUY:** candle tumusok sa ilalim ng range low, tapos bumalik at nag-close sa loob. Liquidity grab pababa → long.
4. **Sweep SELL:** candle tumusok sa taas ng range high, tapos nag-close pabalik sa loob → short.
5. **SL** lampas sa wick ng sweep + buffer. **TP** by R:R (default 1.5) o opposite side ng range.
6. Optional: **limit sa midpoint** ng sweep candle, **secure + trail**, **basket close** kapag slightly green.
7. Default: **isang trade per side per araw** para hindi i-spam ang parehong level.

Optional toggle `InpAllowBreakout=true` kung gusto mo ring i-trade ang close-outside continuation. Default **off**.

## Install (MT5)

1. Kopyahin `EA_NYSweepHunter.mq5` sa `MQL5/Experts/`.
2. Buksan sa MetaEditor → Compile. Target: **0 errors, 0 warnings**.
3. I-attach sa chart:
   - Tickmill: `XAUUSD` o `US30`
   - Deriv: `XAUUSD` / gold alias, o **Wall Street 30**
4. Timeframe: **M5** (mas malinis na sweep) o **M1** (mas maraming signal).
5. Enable **Algo Trading**.
6. Load preset kung meron: `MQL5/Presets/NYSweepHunter_XAUUSD.set` o `NYSweepHunter_US30.set`.

Ang chart symbol = work symbol. Huwag i-hardcode ang pangalan ng gold/US30 sa ibang chart.

## Recommended start (small account)

| Input | XAUUSD | US30 / Wall Street 30 |
|---|---|---|
| Risk % | 2.0 (pwede mong itaas) | 2.0 |
| Fixed lot | 0 (risk-based; $10 → 0.01) | 0 |
| Min sweep | 0 = auto 0.50 | 0 = auto 5.0 |
| SL buffer | 0 = auto 0.30 | 0 = auto 3.0 |
| RR | 1.5 | 1.5 |
| Session | PH 20:00–05:00 | same |
| News blackout | 20:30 at 21:30 PH, 10 min | same |
| Max positions | 1 | 1 |
| One sweep per side | true | true |

TZ offset default **8** (Philippines). Kung ibang broker GMT, baguhin `InpSessionTZOffsetHrs` hanggang tumama ang NY window sa local clock mo.

## Backtest

- Symbol: XAUUSD o US30, **M5**, every tick (o 1-minute OHLC kung mabagal).
- I-on ang visual: dapat may asul/pula na range lines pagkatapos ng Asian window.
- Tester ≠ live. Slippage at spread sa Deriv/Tickmill ay mas malaki kaysa tester.

## Hindi kasama (sinadya)

- Walang ATR, EMA, RSI.
- Walang martingale / grid.
- Spread filter default **off** (`InpMaxSpreadPoints=0`).
- Hindi ito Boom/Crash EA.

Demo muna. Hindi ito guarantee ng tubo.
