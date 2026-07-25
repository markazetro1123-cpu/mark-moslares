//+------------------------------------------------------------------+
//| EA_ColorBurstScalper.mq5                                         |
//| Red=SELL / Green=BUY | buffer arm | one-way pending              |
//| Aggressive lot growth | burst basket TP (small profit close)     |
//+------------------------------------------------------------------+
#property copyright "Mark Moslares"
#property link      "https://github.com/markazetro1123-cpu/mark-moslares"
#property version   "1.00"
#property description "Color candle pending scalper with aggressive lots + burst basket TP"

#include <Trade/Trade.mqh>

//======================================================================
// Inputs
//======================================================================
input group "=== Entry ==="
input double InpBufferDistance    = 1.0;      // Buffer from open before pending (price) e.g. 1.0
input double InpPendingOffset     = 0.2;      // Pending distance from current price
input int    InpMaxBasket         = 3;        // Max open positions (burst entries)
input long   InpMagic             = 260725;   // Magic number

input group "=== Burst / Basket TP ==="
input double InpBurstProfit       = 0.20;     // Close basket when this profit (price) is reached
input double InpBasketTrailStart  = 0.12;     // Start trailing basket after this profit (price)
input double InpBasketTrailGap    = 0.08;     // Trail gap from current price
input bool   InpUseEmergencySL    = true;     // Set emergency SL on fill
input double InpEmergencyStopDist = 5.0;      // Emergency SL distance (price)

input group "=== Aggressive Lot (TikTok-style growth) ==="
input bool   InpUseAggressiveLot  = true;     // Grow lot as capital grows
input double InpBaseLot           = 0.0;      // Base lot (0 = broker min lot)
input double InpLotPerTier        = 1.0;      // Extra lot-steps per equity tier
input double InpRiskPercentStart  = 50.0;     // Start risk room % (aggressive)
input double InpRiskPercentStep   = 5.0;      // Reduce risk % per tier
input double InpRiskPercentFloor  = 15.0;     // Minimum risk %
input double InpFixedLot          = 0.0;      // Fixed lot override (0 = aggressive/auto)

input group "=== Runtime ==="
input double InpMaxDailyLossPct   = 80.0;     // Daily loss lock % (0 = off)
input int    InpSlippagePoints    = 30;       // Slippage points
input bool   InpAllowBuy          = true;     // Allow BUY
input bool   InpAllowSell         = true;     // Allow SELL

//======================================================================
// Helpers
//======================================================================
double CBS_Point(const string symbol)
{
   const double p = SymbolInfoDouble(symbol, SYMBOL_POINT);
   return (p > 0.0 ? p : _Point);
}

int CBS_Digits(const string symbol)
{
   return (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
}

double CBS_NormalizePrice(const string symbol, const double price)
{
   return NormalizeDouble(price, CBS_Digits(symbol));
}

double CBS_NormalizeVolume(const string symbol, double volume)
{
   const double vmin  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   const double vmax  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   const double vstep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(vstep <= 0.0)
      return vmin;
   volume = MathFloor(volume / vstep + 1e-12) * vstep;
   volume = MathMax(vmin, MathMin(vmax, volume));
   int volDigits = 2;
   if(vstep < 0.01) volDigits = 3;
   if(vstep >= 1.0) volDigits = 0;
   return NormalizeDouble(volume, volDigits);
}

bool CBS_SelectFilling(const string symbol, ENUM_ORDER_TYPE_FILLING &filling)
{
   const int modes = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((modes & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
   {
      filling = ORDER_FILLING_IOC;
      return true;
   }
   if((modes & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
   {
      filling = ORDER_FILLING_FOK;
      return true;
   }
   filling = ORDER_FILLING_RETURN;
   return true;
}

double CBS_StopsDist(const string symbol)
{
   const int stops  = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const int freeze = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return MathMax(stops, freeze) * CBS_Point(symbol);
}

bool CBS_TradeAllowed(const string symbol)
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;
   if(SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED) return false;
   return true;
}

int CBS_TierIndex(const double equity)
{
   if(equity < 50.0)   return 0;
   if(equity < 100.0)  return 1;
   if(equity < 200.0)  return 2;
   if(equity < 350.0)  return 3;
   if(equity < 500.0)  return 4;
   if(equity < 750.0)  return 5;
   if(equity < 1000.0) return 6;
   return 7;
}

double CBS_LossPerLot(const string symbol, const double dist)
{
   if(dist <= 0.0) return 0.0;
   const double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   const double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0) return 0.0;
   return (dist / tickSize) * tickValue;
}

double CBS_MaxLotByMargin(const string symbol, const double price, const ENUM_ORDER_TYPE type)
{
   const double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   const double vmin = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   if(free <= 0.0) return vmin;

   double marginOne = 0.0;
   if(!OrderCalcMargin(type, symbol, 1.0, price, marginOne) || marginOne <= 0.0)
   {
      double marginMin = 0.0;
      if(!OrderCalcMargin(type, symbol, vmin, price, marginMin) || marginMin <= 0.0)
         return vmin;
      marginOne = marginMin / vmin;
   }
   // Aggressive: allow up to 70% free margin
   return CBS_NormalizeVolume(symbol, (free * 0.70) / marginOne);
}

double CBS_CalcLot(const string symbol, const ENUM_ORDER_TYPE type, const double refPrice)
{
   if(InpFixedLot > 0.0)
      return CBS_NormalizeVolume(symbol, InpFixedLot);

   const double vmin  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   const double vstep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   const double step  = (vstep > 0.0 ? vstep : vmin);
   double baseLot = (InpBaseLot > 0.0 ? InpBaseLot : vmin);

   if(!InpUseAggressiveLot)
      return CBS_NormalizeVolume(symbol, baseLot);

   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   const int tier = CBS_TierIndex(equity);

   // TikTok-style: lot steps grow as capital grows
   double lot = baseLot + (tier * InpLotPerTier * step);

   // Also size by aggressive risk room vs emergency SL
   double riskPct = InpRiskPercentStart - (tier * InpRiskPercentStep);
   if(riskPct < InpRiskPercentFloor)
      riskPct = InpRiskPercentFloor;

   if(InpEmergencyStopDist > 0.0)
   {
      const double riskMoney = equity * (riskPct / 100.0);
      const double lossPerLot = CBS_LossPerLot(symbol, InpEmergencyStopDist);
      if(lossPerLot > 0.0)
      {
         const double riskLot = riskMoney / lossPerLot;
         // Take the larger of tier-ladder and risk-lot (aggressive), then margin-cap
         lot = MathMax(lot, riskLot);
      }
   }

   lot = MathMin(lot, CBS_MaxLotByMargin(symbol, refPrice, type));
   return CBS_NormalizeVolume(symbol, lot);
}

bool CBS_FindPending(const string symbol, const long magic, const long orderType, ulong &ticket, double &price)
{
   ticket = 0;
   price = 0.0;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      const ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != magic) continue;
      if(OrderGetInteger(ORDER_TYPE) != orderType) continue;
      ticket = t;
      price = OrderGetDouble(ORDER_PRICE_OPEN);
      return true;
   }
   return false;
}

bool CBS_CancelPendingType(CTrade &trade, const string symbol, const long magic, const long orderType)
{
   bool ok = true;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      const ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != magic) continue;
      if(OrderGetInteger(ORDER_TYPE) != orderType) continue;
      if(!trade.OrderDelete(t)) ok = false;
   }
   return ok;
}

bool CBS_CancelAllPending(CTrade &trade, const string symbol, const long magic)
{
   bool ok = true;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      const ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != magic) continue;
      const long typ = OrderGetInteger(ORDER_TYPE);
      if(typ == ORDER_TYPE_BUY || typ == ORDER_TYPE_SELL) continue;
      if(!trade.OrderDelete(t)) ok = false;
   }
   return ok;
}

int CBS_CountPositions(const string symbol, const long magic, const long posTypeFilter = -1)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if(posTypeFilter >= 0 && PositionGetInteger(POSITION_TYPE) != posTypeFilter) continue;
      count++;
   }
   return count;
}

bool CBS_BasketStats(const string symbol, const long magic,
                     int &count, long &side, double &avgPrice, double &totalProfitMoney)
{
   count = 0;
   side = -1;
   avgPrice = 0.0;
   totalProfitMoney = 0.0;
   double volSum = 0.0;
   double pxVol = 0.0;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;

      const long typ = PositionGetInteger(POSITION_TYPE);
      if(side < 0) side = typ;
      else if(side != typ) return false; // mixed sides — not a clean basket

      const double vol = PositionGetDouble(POSITION_VOLUME);
      const double op  = PositionGetDouble(POSITION_PRICE_OPEN);
      volSum += vol;
      pxVol  += op * vol;
      totalProfitMoney += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      count++;
   }

   if(count <= 0 || volSum <= 0.0) return false;
   avgPrice = pxVol / volSum;
   return true;
}

bool CBS_CloseBasket(CTrade &trade, const string symbol, const long magic)
{
   bool ok = true;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      if(!trade.PositionClose(t)) ok = false;
   }
   return ok;
}

//======================================================================
// Globals
//======================================================================
CTrade          g_trade;
string          g_symbol;
ENUM_TIMEFRAMES g_tf;
datetime        g_candleTime = 0;
double          g_candleOpen = 0.0;
int             g_color      = 0; // +1 green, -1 red
bool            g_dailyLock  = false;
double          g_dayStartEq = 0.0;
int             g_dayStamp   = -1;

void RefreshCandle(const bool force);
void UpdateDailyLock();
void ManageBasket();
void ManageEntries();
void EnsureSellStop_TrailUpOnly();
void EnsureBuyStop_TrailDownOnly();
void ApplyEmergencySL();
double CalcLot(const ENUM_ORDER_TYPE type, const double refPrice);

//======================================================================
int OnInit()
{
   g_symbol = _Symbol;
   g_tf = (ENUM_TIMEFRAMES)_Period;

   if(!SymbolSelect(g_symbol, true))
   {
      Print("ERROR: SymbolSelect failed");
      return INIT_FAILED;
   }
   if(InpBufferDistance < 0.0 || InpPendingOffset < 0.0 || InpBurstProfit <= 0.0)
   {
      Print("ERROR: invalid distance / burst inputs");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpMaxBasket < 1)
   {
      Print("ERROR: InpMaxBasket must be >= 1");
      return INIT_PARAMETERS_INCORRECT;
   }

   ENUM_ORDER_TYPE_FILLING fill;
   CBS_SelectFilling(g_symbol, fill);
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFilling(fill);
   g_trade.SetAsyncMode(false);

   g_dayStartEq = AccountInfoDouble(ACCOUNT_EQUITY);
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   g_dayStamp = dt.day_of_year;

   RefreshCandle(true);
   PrintFormat("ColorBurstScalper ready | %s %s | buffer=%.5f offset=%.5f burst=%.5f maxBasket=%d",
               g_symbol, EnumToString(g_tf), InpBufferDistance, InpPendingOffset, InpBurstProfit, InpMaxBasket);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {}

void OnTick()
{
   if(!CBS_TradeAllowed(g_symbol))
      return;

   UpdateDailyLock();
   if(g_dailyLock)
      return;

   RefreshCandle(false);
   ApplyEmergencySL();
   ManageBasket();

   // If basket still open after manage, keep burst pending for same side
   ManageEntries();
}

//======================================================================
void UpdateDailyLock()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != g_dayStamp)
   {
      g_dayStamp = dt.day_of_year;
      g_dayStartEq = AccountInfoDouble(ACCOUNT_EQUITY);
      g_dailyLock = false;
   }
   if(InpMaxDailyLossPct <= 0.0 || g_dayStartEq <= 0.0)
      return;

   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   const double dd = ((g_dayStartEq - eq) / g_dayStartEq) * 100.0;
   if(dd >= InpMaxDailyLossPct)
   {
      if(!g_dailyLock)
      {
         PrintFormat("Daily loss lock %.2f%%", dd);
         CBS_CancelAllPending(g_trade, g_symbol, InpMagic);
      }
      g_dailyLock = true;
   }
}

void RefreshCandle(const bool force)
{
   const datetime t = iTime(g_symbol, g_tf, 0);
   const double o = iOpen(g_symbol, g_tf, 0);
   if(t == 0 || o <= 0.0) return;

   if(force || t != g_candleTime)
   {
      if(!force && g_candleTime != 0)
      {
         CBS_CancelAllPending(g_trade, g_symbol, InpMagic);
         PrintFormat("New candle %s open=%.5f — reset pendings",
                     TimeToString(t, TIME_DATE|TIME_MINUTES), o);
      }
      g_candleTime = t;
      g_candleOpen = o;
   }
   else
      g_candleOpen = o;

   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double mid = (bid + ask) * 0.5;
   const double eps = CBS_Point(g_symbol) * 0.5;

   if(mid > g_candleOpen + eps)      g_color = +1; // GREEN
   else if(mid < g_candleOpen - eps) g_color = -1; // RED
   else                              g_color = 0;
}

bool BufferReadySell()
{
   // Example: open 4401, buffer 1 → need bid <= 4400
   return ((g_candleOpen - SymbolInfoDouble(g_symbol, SYMBOL_BID)) >= InpBufferDistance);
}

bool BufferReadyBuy()
{
   return ((SymbolInfoDouble(g_symbol, SYMBOL_ASK) - g_candleOpen) >= InpBufferDistance);
}

double CalcLot(const ENUM_ORDER_TYPE type, const double refPrice)
{
   return CBS_CalcLot(g_symbol, type, refPrice);
}

//======================================================================
// Basket: small profit close + trail
//======================================================================
void ManageBasket()
{
   int count = 0;
   long side = -1;
   double avg = 0.0;
   double money = 0.0;
   if(!CBS_BasketStats(g_symbol, InpMagic, count, side, avg, money))
      return;

   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double stops = CBS_StopsDist(g_symbol);

   double favor = 0.0;
   if(side == POSITION_TYPE_BUY)
      favor = bid - avg;
   else if(side == POSITION_TYPE_SELL)
      favor = avg - ask;
   else
      return;

   // BURST TP: kahit maliit na profit — close whole basket
   if(favor >= InpBurstProfit)
   {
      PrintFormat("BURST TP hit favor=%.5f money=%.2f — close basket (%d)", favor, money, count);
      CBS_CloseBasket(g_trade, g_symbol, InpMagic);
      CBS_CancelAllPending(g_trade, g_symbol, InpMagic);
      return;
   }

   // Basket trailing after small profit
   if(favor < InpBasketTrailStart)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      const double sl = PositionGetDouble(POSITION_SL);
      const double tp = PositionGetDouble(POSITION_TP);
      const double openPx = PositionGetDouble(POSITION_PRICE_OPEN);

      if(side == POSITION_TYPE_BUY)
      {
         double newSL = CBS_NormalizePrice(g_symbol, bid - InpBasketTrailGap);
         // Lock some profit vs avg / open
         const double floorSL = CBS_NormalizePrice(g_symbol, avg + (InpBasketTrailStart - InpBasketTrailGap));
         if(newSL < floorSL) newSL = floorSL;
         if(newSL > openPx && (sl <= 0.0 || newSL > sl + CBS_Point(g_symbol) * 0.5))
         {
            if(bid - newSL >= stops)
               g_trade.PositionModify(t, newSL, tp);
         }
      }
      else // SELL
      {
         double newSL = CBS_NormalizePrice(g_symbol, ask + InpBasketTrailGap);
         const double floorSL = CBS_NormalizePrice(g_symbol, avg - (InpBasketTrailStart - InpBasketTrailGap));
         if(newSL > floorSL) newSL = floorSL;
         if(newSL < openPx && (sl <= 0.0 || newSL < sl - CBS_Point(g_symbol) * 0.5))
         {
            if(newSL - ask >= stops)
               g_trade.PositionModify(t, newSL, tp);
         }
      }
   }
}

void ApplyEmergencySL()
{
   if(!InpUseEmergencySL || InpEmergencyStopDist <= 0.0)
      return;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      const double sl = PositionGetDouble(POSITION_SL);
      if(sl > 0.0) continue;

      const long typ = PositionGetInteger(POSITION_TYPE);
      const double op = PositionGetDouble(POSITION_PRICE_OPEN);
      const double tp = PositionGetDouble(POSITION_TP);
      const double em = (typ == POSITION_TYPE_BUY)
                        ? CBS_NormalizePrice(g_symbol, op - InpEmergencyStopDist)
                        : CBS_NormalizePrice(g_symbol, op + InpEmergencyStopDist);
      g_trade.PositionModify(t, em, tp);
   }
}

//======================================================================
// Entries: color + buffer → one-way pending (+ burst add-ons)
//======================================================================
void ManageEntries()
{
   const int totalPos = CBS_CountPositions(g_symbol, InpMagic);

   // RED candle + buffer down → SELL pending only
   if(g_color < 0 && InpAllowSell && BufferReadySell())
   {
      CBS_CancelPendingType(g_trade, g_symbol, InpMagic, ORDER_TYPE_BUY_STOP);
      if(totalPos < InpMaxBasket)
         EnsureSellStop_TrailUpOnly();
      else
         CBS_CancelPendingType(g_trade, g_symbol, InpMagic, ORDER_TYPE_SELL_STOP);
      return;
   }

   // GREEN candle + buffer up → BUY pending only
   if(g_color > 0 && InpAllowBuy && BufferReadyBuy())
   {
      CBS_CancelPendingType(g_trade, g_symbol, InpMagic, ORDER_TYPE_SELL_STOP);
      if(totalPos < InpMaxBasket)
         EnsureBuyStop_TrailDownOnly();
      else
         CBS_CancelPendingType(g_trade, g_symbol, InpMagic, ORDER_TYPE_BUY_STOP);
      return;
   }

   // Not armed: cancel both
   CBS_CancelAllPending(g_trade, g_symbol, InpMagic);
}

// SELL STOP always below Bid.
// Price UP  → pending moves UP (follow).
// Price DOWN → pending stays (does NOT move down) until filled.
void EnsureSellStop_TrailUpOnly()
{
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double minDist = MathMax(InpPendingOffset, CBS_StopsDist(g_symbol));
   const double desired = CBS_NormalizePrice(g_symbol, bid - minDist);

   ulong ticket = 0;
   double cur = 0.0;
   if(CBS_FindPending(g_symbol, InpMagic, ORDER_TYPE_SELL_STOP, ticket, cur))
   {
      if(cur >= bid)
      {
         g_trade.OrderDelete(ticket);
      }
      else
      {
         // Only raise (never lower)
         if(desired > cur + CBS_Point(g_symbol) * 0.5)
         {
            if(!g_trade.OrderModify(ticket, desired, 0.0, 0.0, ORDER_TIME_GTC, 0))
               Print("SELL_STOP modify fail: ", g_trade.ResultRetcodeDescription());
         }
         return;
      }
   }

   if(!CBS_FindPending(g_symbol, InpMagic, ORDER_TYPE_SELL_STOP, ticket, cur))
   {
      const double lot = CalcLot(ORDER_TYPE_SELL_STOP, desired);
      if(!g_trade.SellStop(lot, desired, g_symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "CBS SELL"))
         Print("SELL_STOP place fail: ", g_trade.ResultRetcodeDescription());
   }
}

// BUY STOP always above Ask.
// Price DOWN → pending moves DOWN (follow).
// Price UP   → pending stays (does NOT move up) until filled.
void EnsureBuyStop_TrailDownOnly()
{
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double minDist = MathMax(InpPendingOffset, CBS_StopsDist(g_symbol));
   const double desired = CBS_NormalizePrice(g_symbol, ask + minDist);

   ulong ticket = 0;
   double cur = 0.0;
   if(CBS_FindPending(g_symbol, InpMagic, ORDER_TYPE_BUY_STOP, ticket, cur))
   {
      if(cur <= ask)
      {
         g_trade.OrderDelete(ticket);
      }
      else
      {
         // Only lower (never raise)
         if(desired < cur - CBS_Point(g_symbol) * 0.5)
         {
            if(!g_trade.OrderModify(ticket, desired, 0.0, 0.0, ORDER_TIME_GTC, 0))
               Print("BUY_STOP modify fail: ", g_trade.ResultRetcodeDescription());
         }
         return;
      }
   }

   if(!CBS_FindPending(g_symbol, InpMagic, ORDER_TYPE_BUY_STOP, ticket, cur))
   {
      const double lot = CalcLot(ORDER_TYPE_BUY_STOP, desired);
      if(!g_trade.BuyStop(lot, desired, g_symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "CBS BUY"))
         Print("BUY_STOP place fail: ", g_trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
