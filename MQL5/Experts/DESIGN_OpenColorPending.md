# EA_OpenColorPending — Full Design v2.00

**Status:** Confirmed design — implemented in `EA_OpenColorPending.mq5` v2.00  
**Symbol scope:** XAUUSD + US30  
**Style:** Single-file MQL5 Expert Advisor  
**Kept from previous EA:** Dynamic lot by equity, dynamic entries (max 15), no martingale, emergency SL, position trail SL after fill

---

## 1. Goal

Trade **with candle color** using pending orders that:

1. Wait for structure (anti-fakeout delay)
2. Place on the correct side only
3. Trail pending in one direction only (toward open, never through open)
4. Optionally place an opposite pending **at open** when buffer is large enough
5. After fill → trail position SL → on profit → repeat cycle

---

## 2. Candle color definition

Every current candle has an **open price**.

| Market vs Open | Color | Main side |
|---|---|---|
| Mid/price **above** open | **GREEN** | **BUY only** (main) |
| Mid/price **below** open | **RED** | **SELL only** (main) |
| Equal open | **FLAT** | No new main pending |

**Color source:** compare live mid `(bid+ask)/2` to current candle open.

---

## 3. Session / lifecycle per candle

```
NEW CANDLE
   │
   ├─ Reset cycle flags (profit-lock / pending state as needed)
   ├─ Record: open, startTime, prevHigh, prevLow (reference)
   │
   ├─ DELAY WINDOW (default 5 minutes)
   │     └─ NO pending placement yet (structure forming)
   │
   ├─ AFTER DELAY → pending engine ON
   │     ├─ Main side pending (color-based)
   │     └─ Optional opposite pending @ OPEN (3-buffer rule)
   │
   ├─ ON FILL → manage position (emergency SL + trail SL)
   │
   └─ ON PROFIT CLOSE → restart pending cycle under same rules
```

---

## 4. Anti-fakeout delay (5 minutes)

**Input:** `InpStructureDelayMinutes = 5`

Rules:

1. On new candle, store `g_bar_time` / `g_delay_until = openTime + 5 minutes`
2. While `TimeCurrent() < g_delay_until`:
   - Do **not** place new pendings
   - May still manage already-open positions / trail SL
3. After delay expires → pending logic may run

Purpose: hayaan munang mag-buo ang candle structure bago pumasok.

---

## 5. Main BUY engine (GREEN)

### Example
- Open = `4400`
- Price rises to `4401.5` → GREEN
- After delay → place **BUY pending at latest HIGH**

### Placement
- Order type: Buy Stop / Buy pending at **current candle latest HIGH**
- Only when color = GREEN
- Only after delay
- No SELL main-side orders while GREEN

### Pending trail rules (BUY)
| Price action | Buy pending behavior |
|---|---|
| Price makes **new higher high** | **Do NOT raise** pending (no chase up) |
| Price **falls** | Pending **trails down** with structure / lower highs path |
| Pending vs Open | Pending **cannot go below Open** (floor = open) |

### Visual
```
                    new highs → ignore (no raise)
   ★ initial BUY pending @ latest high
              │
              │ price down → trail pending down
              ▼
   ★ pending lower...
              │
   ───────────� trail pending down
              ▼
   ★ pending lower...
              │
   ───────────┴──────── Open = FLOOR (stop trailing here)
```

### After BUY fill
1. Attach / keep **emergency SL**
2. **Trail position SL** in profit direction (existing trail style; e.g. US30 fill `4399` → SL around `4399.5` distance model)
3. If closed in **profit** → allow new pending cycle again (same candle rules still apply if still valid)

---

## 6. Main SELL engine (RED) — mirror of BUY

### Placement
- Order type: Sell Stop / Sell pending at **current candle latest LOW**
- Only when color = RED
- Only after delay
- No BUY main-side orders while RED

### Pending trail rules (SELL)
| Price action | Sell pending behavior |
|---|---|
| Price makes **new lower low** | **Do NOT lower** pending (no chase down) |
| Price **rises** | Pending **trails up** |
| Pending vs Open | Pending **cannot go above Open** (ceiling = open) |

### Visual
```
   ───────────┬──────── Open = CEILING (stop trailing here)
              │
   ★ pending higher...
              ▲
              │ price up → trail pending up
              │
   ★ initial SELL pending @ latest low
                    new lows → ignore (no lower)
```

### After SELL fill
Same as buy: emergency SL + trail SL → profit close → cycle again.

---

## 7. 3-buffer-points rule (opposite pending at OPEN)

**Input:** `InpOpenBufferPoints = 3` (points)

**Distance:** `|currentPrice - candleOpen|` in points.

### When GREEN and buffer ≥ 3
- Place **SELL pending at OPEN price**
- This is **not** at latest low
- If buffer **< 3** → **do not** place sell@open

### When RED and buffer ≥ 3
- Place **BUY pending at OPEN price**
- This is **not** at latest high
- If buffer **< 3** → **do not** place buy@open

### Intent
Main side follows candle color extremes (with one-way trail).  
Opposite side only appears at **open** when there is enough room (buffer), to avoid noise / fake open fades.

### Combined GREEN example
```
Price 4403+     (buffer OK vs open 4400)
★ BUY pending   @ high, trails down only, floor=open
★ SELL pending  @ OPEN 4400   ← only because buffer ≥ 3
Open 4400
```

### Combined RED example
```
Open 4400
★ BUY pending   @ OPEN 4400   ← only because buffer ≥ 3
★ SELL pending  @ low, trails up only, ceiling=open
Price 4397-     (buffer OK)
```

---

## 8. Hard side locks

| Candle color | Allowed |
|---|---|
| GREEN | Main BUY trail + optional SELL@open (if buffer≥3) |
| RED | Main SELL trail + optional BUY@open (if buffer≥3) |
| FLAT | No new pendings |

If color flips mid-candle:

1. Cancel invalid main-side pendings for the old color
2. Re-evaluate after delay already passed (delay is once per candle, not reset on color flip)
3. Apply new color rules immediately

---

## 9. Pending trail boundaries (summary)

| Side | Initial anchor | Trail direction | Hard stop |
|---|---|---|---|
| BUY main | Latest HIGH | Down only | ≥ Open |
| SELL main | Latest LOW | Up only | ≤ Open |
| SELL@open | Open | Fixed at open (or re-anchor to open) | Open |
| BUY@open | Open | Fixed at open (or re-anchor to open) | Open |

---

## 10. Position management (after fill)

Kept / required:

1. **Emergency SL** always attached on fill (distance auto by symbol if input=0)
2. **Trail SL** after price moves in favor (auto distance by symbol if input=0)
3. No martingale
4. Same cycle lot per candle (dynamic lot computed once per cycle)
5. Dynamic entries by equity (example: ~$30–$50 → 2–3 entries, max 15)

### Profit cycle
If a position closes in **profit**:
- Cancel pendings as needed
- Re-arm pending logic for continued opportunity under current candle rules
  (or lock until structure re-check — implementation default: allow re-pending same candle after profit, still respecting delay already satisfied and color/buffer rules)

---

## 11. Dynamic lot & entries (kept)

### Lot
- Risk % of equity vs emergency distance
- Caps: broker min/max, `InpMaxLotCap`, margin safety
- Freeze lot for the active cycle (`g_cycle_lot`)

### Entries
Equity bands → allowed concurrent entries, hard max `15`.

---

## 12. Inputs (design target)

| Input | Default | Meaning |
|---|---|---|
| `InpMagic` | 260728 | Magic |
| `InpRiskPercent` | 2.0 | Dynamic lot risk % |
| `InpMinLot` | 0.01 | Min lot |
| `InpMaxLotCap` | 1.00 | Max lot |
| `InpSlippagePoints` | 40 | Deviation |
| `InpAllowBuy` | true | Master buy enable |
| `InpAllowSell` | true | Master sell enable |
| `InpStructureDelayMinutes` | 5 | Anti-fakeout delay |
| `InpOpenBufferPoints` | 3 | Buffer for opposite pending @ open |
| `InpTrailDistance` | 0 | Position trail (0=auto) |
| `InpEmergencySL` | 0 | Emergency SL (0=auto) |
| `InpPendingOffset` | 0 | Broker gap helper (0=auto) |
| `InpPrintLogs` | true | Logs |

---

## 13. Tick algorithm (implementation blueprint)

```
OnTick:
  if symbol not XAUUSD/US30 → return
  copy bar0 (time, open, high, low)
  copy bar1 (prev high/low reference)

  if new bar:
      reset cycle lot / pending state
      set delayUntil = bar0.time + delayMinutes

  manage open positions (emergency + trail SL)

  update comment UI

  if TimeCurrent() < delayUntil:
      return   // structure delay

  color = detect(open, mid)

  if color == GREEN:
      cancel main SELL pendings (latest-low style)
      place/update BUY main:
          - if none: place at latest high
          - if exists: only modify DOWN, never below open, never UP
      if distancePoints(mid, open) >= buffer:
          place/keep SELL pending at open
      else:
          delete SELL@open

  else if color == RED:
      cancel main BUY pendings (latest-high style)
      place/update SELL main:
          - if none: place at latest low
          - if exists: only modify UP, never above open, never DOWN
      if distancePoints(mid, open) >= buffer:
          place/keep BUY pending at open
      else:
          delete BUY@open

  else: // FLAT
      cancel main extreme pendings (keep optional open-pendings only if buffer still valid, or cancel all — default cancel all mains)
```

---

## 14. OnTradeTransaction

On deal out:
- If EA magic + symbol and profit > 0 → mark profit event, cancel stale pendings, allow fresh pending cycle under current rules.

---

## 15. Non-goals (for this version)

- No news filter
- No session filter
- No martingale / grid multiply
- No multi-symbol basket
- No chase of extremes away from open (BUY never raises; SELL never lowers)

---

## 16. Acceptance checklist

1. First 5 minutes of candle → no new pendings
2. GREEN → main BUY only at high; trails down only; stops at open
3. RED → main SELL only at low; trails up only; stops at open
4. GREEN + buffer≥3 → SELL pending exactly at open (not low)
5. RED + buffer≥3 → BUY pending exactly at open (not high)
6. Buffer <3 → no opposite@open
7. Fill → emergency SL + trail SL works
8. Dynamic lot/entries still active
9. Compiles with 0 errors / 0 warnings

---

## 17. File plan

| File | Role |
|---|---|
| `MQL5/Experts/DESIGN_OpenColorPending.md` | This design (source of truth) |
| `MQL5/Experts/EA_OpenColorPending.mq5` | Implementation (to update next) |
| `MQL5/Experts/README_OpenColorPending.md` | Short install notes |

---

**Design version:** v2.00  
**Confirmed by user:** yes (structure understanding OK)
