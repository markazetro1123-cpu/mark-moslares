# Limitless Scalp EA — Lot Sizing Specification

Status: **frozen design for Phase 1; not MQL5 implementation**

## 1. Objective

Preserve the observed ExpertGold1 execution style—one directional basket,
optional same-size add, and bulk close—without copying the videos' destructive
1.00–2.00 fixed lots or negative-free-margin behavior.

The lot calculator is broker- and symbol-normalized. It must work from live
contract data for both Gold (`XAUUSD*`) and Deriv Wall Street 30.

## 2. Default $10 profile

| Setting | Default |
| --- | ---: |
| Sizing mode | Equity-risk |
| Planned first-entry risk | 1.50% |
| Hard basket risk ceiling | 2.00% |
| Slippage/cost reserve | 0.50% |
| Maximum layers below $20 equity | 1 |
| Maximum layers at/above $20 equity | 2 |
| Daily loss lockout | 5.00% or 3 losing baskets |
| Martingale / loss multiplier | Disabled |
| Forced broker-minimum lot | Forbidden |

At $10 equity, planned risk is `$0.15` and the absolute basket ceiling is
`$0.20`. The spare `$0.05` is not extra entry risk; it is a reserve for
commission, spread expansion, slippage, and close latency.

## 3. Risk base

Use:

```text
risk_base = min(current_equity, day_start_equity)
```

This immediately reduces size during drawdown and prevents intraday
compounding after a temporary gain. The day-start value resets at the configured
broker-day boundary only when no EA basket is open.

Global account policy below $20:

- at most one Limitless EA basket across all attached symbols;
- total projected open EA risk must remain at or below 2% of `risk_base`; and
- an XAUUSD instance and a Wall Street 30 instance cannot each consume a
  separate 2% budget at the same time.

## 4. Emergency stop distance

Risk-based volume is invalid without a real stop price. For a qualified
continuation impulse:

- BUY invalidation is below the qualified impulse origin / protected rolling
  low;
- SELL invalidation is above the qualified impulse origin / protected rolling
  high;
- the distance must also satisfy broker stop/freeze constraints and cover
  expected round-trip cost;
- if no valid structural invalidation price exists, reject the trade.

The EA places a broker-side catastrophe stop for every position. The
BasketManager may close sooner on basket loss, opposite impulse, timeout, or
margin danger. A synthetic basket stop alone is insufficient for sizing.

## 5. Per-lot loss calculation

Do not hardcode pip value. Before sending an order, calculate the projected loss
for `1.0` lot from entry to emergency stop with the broker's symbol data:

```text
market_loss_per_lot =
    abs(OrderCalcProfit(side, symbol, 1.0, entry_price, stop_price))

cost_per_lot =
    estimated_commission_per_lot
  + estimated_exit_spread_loss_per_lot
  + slippage_buffer_per_lot

total_loss_per_lot = market_loss_per_lot + cost_per_lot
```

Reject with `LOT_INVALID_TICK_VALUE` or `LOT_INVALID_STOP_DISTANCE` when the
calculation is non-finite, zero, or inconsistent with tick size/value.

## 6. Raw and normalized volume

For equity below $20:

```text
planned_risk_money = risk_base * 0.015
hard_basket_money   = risk_base * 0.020

raw_volume = planned_risk_money / total_loss_per_lot
volume = floor(raw_volume / volume_step) * volume_step
```

Normalization rules:

1. Round **down**, never to nearest and never up.
2. Respect `SYMBOL_VOLUME_STEP` precision.
3. If `raw_volume < SYMBOL_VOLUME_MIN`, return `LOT_MIN_EXCEEDS_RISK` and skip.
4. Never clamp an unaffordable raw volume up to the broker minimum.
5. Cap at `SYMBOL_VOLUME_MAX` and the account's remaining global risk budget.
6. Recalculate projected loss using the normalized volume.
7. Reject if projected basket loss plus costs exceeds the 2% ceiling.

At $10, `0.01` is not automatically safe. Whether it fits depends on the actual
Gold or Wall Street 30 contract, stop distance, spread, leverage, and account
currency.

## 7. Margin gates

Risk affordability and margin affordability are separate gates. Use
`OrderCalcMargin` for the proposed order and reject when any condition fails:

- insufficient free margin;
- projected free margin below the configured reserve;
- projected margin level below `InpMinProjectedMarginLevel`;
- symbol/account trade mode disallows the order; or
- broker calculation returns invalid data.

Phase 1 defaults:

```text
InpMinProjectedMarginLevel = 500%
InpEmergencyMarginLevel    = 250%
```

These are `OUR_RULE` safety defaults, not values observed in the videos.
Broker stop-out level is always read at runtime; the EA may use stricter
thresholds but never a weaker threshold than required to avoid stop-out.

## 8. Optional second layer

`MaxLayers = 1` below $20. At/above $20, a second layer may be enabled, but the
absolute hard basket ceiling remains 2%.

To preserve the observed fixed-lot-within-basket style:

1. Calculate a base unit volume at the first entry.
2. The optional add requests the **same normalized unit volume**.
3. Simulate the total loss of both positions to the common basket invalidation
   stop, including costs.
4. Veto the add if total projected basket loss would exceed 2%.
5. Do not shrink or increase the second volume merely to force an add.
6. Add only with score ≥80, favorable progression, basket not losing, and
   spacing/cooldown gates satisfied.

For a two-layer-enabled profile, each unit initially targets no more than 0.80%
planned risk, leaving 0.40% of the 2% ceiling as execution reserve:

```text
planned_unit_risk = risk_base * 0.008
two_units         = risk_base * 0.016
hard_ceiling      = risk_base * 0.020
```

## 9. Recalculation and immutability

- Calculate volume once immediately before the first order.
- Freeze the basket's base unit volume and common invalidation stop after fill.
- Do not increase volume because the previous basket lost.
- Do not increase volume from floating profit.
- Recalculate only for a genuinely new movement/basket after cooldown.
- After partial fills, recompute remaining risk before any retry or add.

## 10. Required reason codes and telemetry

Every sizing decision emits:

- symbol and account currency;
- equity, day-start equity, and `risk_base`;
- planned and hard risk money;
- entry, stop, stop distance, tick size/value;
- estimated spread, commission, slippage, and total loss per lot;
- raw volume, normalized volume, min/step/max;
- projected margin, free margin, and margin level;
- existing EA open risk and remaining global budget; and
- final decision/reason code.

Minimum reason codes:

```text
LOT_OK
LOT_MIN_EXCEEDS_RISK
LOT_BASKET_RISK_EXCEEDED
LOT_GLOBAL_RISK_EXCEEDED
LOT_INVALID_STOP_DISTANCE
LOT_INVALID_TICK_VALUE
LOT_INVALID_VOLUME_STEP
LOT_MARGIN_CALC_FAILED
LOT_MARGIN_LEVEL_LOW
LOT_FREE_MARGIN_LOW
LOT_LAYER_NOT_ALLOWED
LOT_ADD_RISK_EXCEEDED
```

## 11. Acceptance tests

The MoneyManager is compliant only when tests prove:

1. `$10`, raw `0.006`, broker minimum `0.01` → skip; never round up.
2. `$10`, normalized volume whose stop loss exceeds `$0.20` → skip.
3. Wider stop distance produces equal or smaller volume.
4. Higher spread/commission/slippage produces equal or smaller volume.
5. Falling equity reduces or preserves volume; never increases it.
6. A Gold lot formula is not reused as a Wall Street 30 point formula.
7. Two chart instances cannot each reserve the same global $10 risk budget.
8. Second layer is impossible below $20.
9. Add-to-loser and martingale paths are impossible.
10. Invalid broker contract/margin data always fails closed.
11. Every accept/reject path emits a deterministic reason code.

## 12. Truth boundary

This design copies the video's **fixed-unit directional basket behavior**, not
its displayed lot numbers. Exact volume is intentionally determined by current
equity, structural stop risk, live broker contract values, costs, and margin.
That is the only defensible way to target the same behavior with a $10 account.
