# EA_CandleGridTrail v1.00

Grid mula sa **candle open**. Ang Inputs sa Strategy Tester = same values sa live. Walang tester-only logic.

## Rules

Open `4400`, grid `0.2` (input):

- Walang entry sa `4400`
- Tumaas → market BUY `4400.2`, `4400.4`, `4400.6`…
- Bumaba → market SELL `4399.8`, `4399.6`…
- Walang pending
- Trail `0.3` mula sa current price (input), one-way
- Bagong candle: bagong grid; lumang positions **maiiwan**, tuloy ang trail
- Lot `0.01` fixed (input)

## Inputs (tester = live)

| Input | Default |
|---|---|
| InpGridStep | 0.2 |
| InpTrailDistance | 0.3 |
| InpLot | 0.01 |

Kailangan **hedge** account (buy at sell sabay).

Kung ang broker stop-level ay mas malaki sa 0.3, kailangang i-widen ang trail sa Inputs — pareho sa tester at live.

## Install

Copy `EA_CandleGridTrail.mq5` → `MQL5/Experts/` → Compile → attach. Demo muna.
