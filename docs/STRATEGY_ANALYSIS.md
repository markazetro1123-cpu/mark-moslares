# Poverty Scalper Robot — Strategy Analysis

> Basehan: publicly available na deskripsyon ng "Poverty Scalper Robot" (TikTok / Telegram / APK listings).
> **Hindi** ito official source code ng kanilang EA — reverse-understanding lang ng ipinapakita/inaadvertise nilang behavior. Ang TikTok page mismo ay naka-block sa automated access (403), kaya galing sa multiple na public writeups ang analysis na ito.

## Ano ang EA na 'to?

Isang **Expert Advisor (EA)** para sa MetaTrader (MT4/MT5) at sa Deriv platform. Ini-market bilang "plug-and-play" na **scalping robot**. Kumakalat sa TikTok, Telegram, WhatsApp — walang official website, walang verified developer, at **walang verified track record** (walang Myfxbook/FXBlue).

## Core na "style" na ginagaya natin

| Element | Ginagamit nila (base sa public info) |
|---|---|
| Timeframe | **M1 (1 minuto)** — dito talaga sila naka-tune |
| Instruments | 5 major FX pairs, XAUUSD (gold), minsan Deriv synthetics (V75/V100), GBPJPY |
| Approach | High-frequency **scalping** — madalas mag-entry, maliliit na target |
| Entry | Momentum / price-action imbalance — "kapag may lumabas na igsi na momentum, papasok" |
| Take Profit | Maliit (modest), madalas malapit sa 1:1 RR |
| Stop Loss | **Napaka-sikip** — minsan 5 pips o mas maliit pa |
| Trade mgmt | Auto-lagay ng TP/SL sa bawat trade |
| Risk feature | **Max drawdown %** protection |
| Session | Best sa London/NY open at overlap; iwas Asian (choppy, lumalapad ang spread) |
| Display | On-chart **stats panel** para makita agad ang performance |
| Setup | Pre-configured defaults; lot size lang ang inaadjust ng user |

## Ang math ng scalper na 'to

Small TP + tight SL ≈ **1:1 (o mas mabuti) risk-reward**. Kapag ang win rate ay ~7/10, profitable. Hindi kailangang mahuli ang malalaking moves — dami ng maliliit na panalo ang habol.

## ⚠️ Mga red flag (importanteng malaman)

Ayon sa mga security/broker writeups:

- **Walang verified results** — madaling i-photoshop ang screenshots.
- **Posibleng may hidden martingale / grid** — dito nanggagaling ang biglaang account blow-up. Ang "poverty" sa pangalan ay parang babala na mismo.
- **Broker/spread sensitive** — sa M1, 2-pip spread lang, ubos na ang edge. Kailangan raw ECN/low spread.
- **Cracked/modified builds** — minsan may kasamang malware ang mga APK/EX4/EX5 mula sa Telegram/Google Drive.

## Paano natin ni-replicate (transparent version)

Ang `PovertyScalperClone.mq5` ay **malinis at bukas** na re-implementation ng *style*, hindi kopya ng binary nila:

1. **M1 scalping** — parehong timeframe.
2. **Momentum + trend entry** — Fast/Slow EMA cross (direction) + RSI (momentum) + minimum candle body (imbalance filter). Ito ang transparent na katumbas ng "momentum imbalance" na sinasabi nila.
3. **Fixed TP/SL** sa bawat trade (adjustable sa points).
4. **Spread filter** — di papasok kung masyadong lumapad.
5. **Session filter** — London/NY hours lang, may Friday cutoff.
6. **Max drawdown guard** — hihinto sa bagong trades kapag lumampas sa % limit.
7. **Trailing stop** — optional, para i-secure ang profit.
8. **On-chart panel** — kagaya ng stats panel nila.

### Sadyang HINDI natin isinama
- **Hidden martingale / grid recovery.** Ito ang pinaka-mapanganib na parte at madalas dahilan ng blow-up. Kung talagang gusto mo i-test, iparameter mo nang bukas at may babala — huwag itago. (Default: wala.)

## Mga variant na binuo

| Variant | File | Para saan |
|---|---|---|
| MT5 EA | `MQL5/Experts/PovertyScalperClone/PovertyScalperClone.mq5` | FX majors / XAUUSD / Deriv synthetics |
| MT4 EA | `MQL4/Experts/PovertyScalperClone/PovertyScalperClone.mq4` | FX majors / XAUUSD (MT4 brokers) |
| Majors preset | `MQL5/Presets/MajorsScalper.set` | Tight scalper defaults (30/30, London/NY overlap) |
| Deriv V75 preset | `MQL5/Presets/DerivV75.set` | Volatility 75 Index (session off, malaking points — i-calibrate) |

Pareho ang logic ng MT4 at MT5; nag-iiba lang ang API (handles + `CTrade` sa MT5, `OrderSend`/`MarketInfo` sa MT4). Ang TP/SL ay auto-clamp sa broker minimum stop distance.

## Paano i-tune para lumapit sa "style" nila

- Gawing mas sikip ang `InpStopLossPts` at `InpTakeProfitPts` (halimbawa 30/30) para mas "scalper".
- `InpMomentumBodyPts` mas mataas = mas piling entries lang.
- I-restrict ang `InpSessionStartHour/EndHour` sa London/NY overlap (server time).
- Palaging i-backtest muna sa Strategy Tester bago i-demo, at DEMO bago mag-live.
