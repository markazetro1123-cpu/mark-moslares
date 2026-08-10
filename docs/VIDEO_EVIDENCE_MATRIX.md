# ExpertGold1 Multi-Video Evidence Matrix

Status: **frame-reviewed evidence; not a profitability proof**

## Sources

| Supplied link | Resolved video ID | Duration | Result |
| --- | --- | ---: | --- |
| `https://vt.tiktok.com/ZS4nm6uRX/` | `7670930749335358741` | 58s | Reviewed |
| `https://vt.tiktok.com/ZS4nmmHke/` | `7670930749335358741` | 58s | Duplicate of the first link |
| `https://vt.tiktok.com/ZS4nmhsx9/` | `7670199496508263700` | 46s | Reviewed |
| `https://vt.tiktok.com/ZS4nmvSTH/` | `7668344923409796373` | 62s | Reviewed |
| `https://vt.tiktok.com/ZS4nmCHPx/` | `7660174167156739349` | 52s | Reviewed |

The five links contain four unique videos. All four show MT5 mobile and
`XAUUSDm`. Chart views include M1, M5, and predominantly M15. No classic
indicator is visible.

## Entry trigger class (locked from multi-video review)

`OBSERVED`: entries are **price-movement / impulse mash** on a naked chart.

- One-click SELL/BUY taps during live candle fluctuation.
- No RSI, MA, MACD, oscillator, or other classic panels on any of the four clips.
- Spacing between stacked fills is irregular/tight (finger-mash cadence), not a
  fixed pip grid.
- User intent matches this class: scalp **price movement**, not an indicator
  crossover.

`UNKNOWN`: the exact tick thresholds, velocity cutoffs, or discretionary filter
the human used for each mash. Those cannot be reverse-engineered from edited
highlights, so Phase 1 encodes a deterministic tick-window qualifier instead of
inventing a secret formula.

## Evidence labels

- `OBSERVED`: directly readable from one or more frames.
- `INFERRED`: plausible interpretation, but the decisive action is off-screen or
  hidden by an edit.
- `UNKNOWN`: the videos do not provide the required information.
- `OUR_RULE`: a deliberate EA safety/design choice, not copied from the videos.

## Clip-level findings

### Video `7670930749335358741`

`OBSERVED`

- The first two supplied links resolve to this same video.
- The clip is edited: the phone clock jumps through approximately 5:04, 5:11,
  5:16, 5:38, and 5:40.
- Multiple 1.00-lot XAUUSDm positions are opened at identical or very close
  prices, confirming rapid burst entries rather than a widely spaced grid.
- At about 5.5s, visible BUY entries near 4262.146–4262.249 are profitable with
  price near 4265.315. Balance is 205.40 USD, equity 18,747.30 USD, margin
  14,706.07 USD, and margin level 127.48%.
- A SELL basket later changes from approximately -3,402.80 USD with negative
  free margin and 88.23% margin level to approximately +17,717 USD.
- The MT5 Bulk Operations menu is shown. Balance rises while positions disappear
  in chunks, which is consistent with bulk-close processing.
- Later sections show another profitable SELL basket and then a profitable BUY
  basket. Direction is not permanently fixed.

`INFERRED`

- BUYs after a sharp fall and SELLs after a rebound resemble confirmed
  post-spike reversals.
- A later BUY basket during the rebound resembles short-horizon continuation.

`UNKNOWN`

- The exact first-entry trigger for each edited section.
- Whether losing positions were manually cut, stopped out, or omitted by edits.

### Video `7670199496508263700`

`OBSERVED`

- The same open SELL basket is inspected on M15, M5, and M1.
- Visible 1.00-lot SELL entries cluster near 4085.848–4086.194.
- With a 4,900.00 USD balance, basket P/L moves from approximately +553.80 USD
  to -1,338.30 USD; margin level reaches 34.19% and free margin is approximately
  -6,855.05 USD.
- The position is held through the adverse move. Near the end, floating P/L is
  approximately +26,827.20 USD and the Bulk Operations menu is opened.
- The chart shows a large upswing followed by rejection and decline; the SELL
  entries are below the visible extreme high.

`INFERRED`

- The basket is a rejection-confirmed top fade rather than a blind sell merely
  because a candle became large.

`UNKNOWN`

- Whether any positions were opened before the recording.
- The selected bulk-close option and exact realized total after the clip ends.

### Video `7668344923409796373`

`OBSERVED`

- A BUY basket of 1.00-lot entries is already profitable during a strong rebound
  from a sharp low.
- One frame shows balance 100.00 USD, floating P/L approximately +38,462.10 USD,
  margin 39,518.95 USD, free margin -956.85 USD, and margin level 97.58%.
- The BUY basket is closed in chunks; balance becomes 40,362.20 USD.
- A new SELL basket is then opened in clustered 2.00-lot positions near
  4082.264–4082.776, confirming an explicit BUY-to-SELL direction flip.
- The SELL basket shows approximately -12,479.00 USD floating loss in one
  section and later more than +50,000 USD floating profit.
- Bulk Operations is shown near the end, followed by no open positions and a
  displayed balance of 92,689.40 USD.

`INFERRED`

- BUYs participate in the rebound after a downside exhaustion event.
- SELLs near the rebound high represent a post-spike fade after rejection.

`UNKNOWN`

- Account type, leverage schedule, credit/bonus, server, and whether this is a
  live, demo, cent, or otherwise modified account.
- Whether all intermediate states are continuous; margin changes are not fully
  explained by the visible positions.

### Video `7660174167156739349`

`OBSERVED`

- The clip begins with a displayed balance of 1,117.84 USD.
- Between adjacent early views, many 1.60-lot SELL positions appear near
  4044.225–4044.514 after a large bearish M15 candle.
- Additional entry lines appear lower as price falls, consistent with continued
  same-side stacking during favorable movement.
- Floating P/L is approximately +4,740.16 USD with 47.67% margin level and
  -6,430.98 USD free margin, later rises above +43,000 USD, then retraces to
  approximately +11,009.12 USD with 29.31% margin level and -29,246.40 USD free
  margin.
- The basket is not closed merely because it first becomes positive. A large
  profit giveback is tolerated.
- Bulk Operations is displayed early, but no final flat account is shown in
  this clip.

`INFERRED`

- This is the clearest momentum-continuation example: SELL entries follow and
  continue with a strong bearish move.

`UNKNOWN`

- Whether lower entries were added only while the basket was profitable.
- The actual exit and realized result.

## Cross-video behavior matrix

| Behavior claim | Label | Evidence |
| --- | --- | --- |
| Rapid same-side entry bursts | `OBSERVED` | Repeated identical/near-identical entry prices |
| Fixed lot within a basket | `OBSERVED` | 1.00, 1.60, or 2.00 repeated per shown basket |
| Lot size changes between sessions | `OBSERVED` | Different clips/baskets use different fixed lots |
| Both BUY and SELL baskets | `OBSERVED` | All directions appear; one clip directly flips BUY to SELL |
| Momentum continuation mode | `OBSERVED` | 1.60-lot SELL stack during the large bearish move |
| Rejection-confirmed fade mode | `INFERRED` | Buys after sharp lows and sells after rebound highs |
| Entry on every micro-spike | `UNKNOWN` | Clips show selected large moves, not every fluctuation |
| Fixed grid spacing | `CONTRADICTED` | Many entries share the same price or irregular tight spacing |
| Tight stop-loss behavior | `CONTRADICTED` | Severe floating loss and margin stress are visible |
| Close immediately when first positive | `CONTRADICTED` | Large positive baskets are held and sometimes give back profit |
| Bulk-close basket behavior | `OBSERVED` | Bulk Operations plus chunked/final flat closures |
| Safe money management | `CONTRADICTED` | Negative free margin and 29–98% margin levels appear |
| Long-term profitability | `UNKNOWN` | No complete history, losses, deposits, or independent statement |
| Exact hidden “instinct” formula | `UNKNOWN` | Opening context is absent or edited in key sequences |

## Behavior we can reproduce

1. Detect an abnormal move from raw ticks and multi-timeframe price context.
2. Classify it as:
   - continuation after directional persistence; or
   - exhaustion/rejection followed by confirmed opposite velocity.
3. Enter one side only.
4. Permit burst/pyramid adds only while continuation remains confirmed.
5. Track all positions as one basket.
6. Close the whole basket when net target, opposite impulse, timeout, risk limit,
   or margin emergency fires.
7. Re-arm only after the current movement resets.

## Behavior we will not copy

The following are visible but intentionally rejected as EA requirements:

- 1.00–2.00 fixed lots on tiny balances;
- negative free margin;
- margin levels near stop-out;
- uncapped rapid-fire entries;
- holding without a defined basket-loss exit; and
- presenting selected winning clips as proof of repeatable profitability.

Those behaviors can create the displayed upside only by accepting a substantial
probability of account loss. They are not compatible with the requested 10 USD
capital protection.

## Replication decision

- Observable execution style: sufficiently documented for a deterministic
  behavior specification.
- Exact entry formula: not exposed by the footage.
- Exact profit replication: not testable from edited highlights.
- Phase 1 direction: continuation-only remains the safe starting mode.
- Phase 2 candidate: rejection-confirmed fade, disabled until independently
  replayed and forward-tested.
