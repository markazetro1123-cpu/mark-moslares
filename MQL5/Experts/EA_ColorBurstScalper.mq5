//+------------------------------------------------------------------+
//| EA_ColorBurstScalper.mq5                                         |
//| Full single-file EA (copy this one file only)                    |
//|                                                                  |
//| - Works on ANY chart timeframe (uses attached TF only)           |
//| - RED = SELL / GREEN = BUY                                       |
//| - First arm: open +/- buffer                                     |
//| - Re-entry after close: current +/- reentry gap                  |
//| - One-way trailing pending                                       |
//| - Aggressive lot growth                                          |
//| - Burst basket TP + basket trail                                 |
//| - Active only 20:00-05:00 PH time (UTC+8)                        |
//+------------------------------------------------------------------+
#property copyright "Mark Moslares"
#property link      "https://github.com/markazetro1123-cpu/mark-moslares"
#property version   "1.00"
#property description "ColorBurstScalper: NY/PH session, color pending, burst basket (single file)"

#include <Trade/Trade.mqh>

//======================================================================
// INPUTS
//======================================================================
input group "=== Session (PH time UTC+8) ==="
input bool   InpUseSessionFilter     = true;   // Use session filter
input int    InpSessionTZOffsetHours = 8;      // Timezone offset from GMT (PH=8)
input int    InpSessionStartHour     = 20;     // Start hour PH (8PM)
input int    InpSessionStartMinute   = 0;      // Start minute
input int    InpSessionEndHour       = 5;      // End hour PH (5AM)
input int    InpSessionEndMinute     = 0;      // End minute

input group "=== Entry ==="
input double InpBufferDistance       = 1.0;    // First arm buffer from candle open (price)
input double InpPendingOffset        = 0.2;    // Pending gap from market price
input double InpReentryGap           = 1.0;    // After close: pending gap from current price
input int    InpMaxBasket            = 3;      // Max open positions (burst)
input long   InpMagic                = 260725; // Magic number

input group "=== Burst / Basket ==="
input double InpBurstProfit          = 0.20;   // Close basket at this profit (price)
input double InpBasketTrailStart     = 0.12;   // Start basket trail at this profit
input double InpBasketTrailGap       = 0.08;   // Basket trail distance
input bool   InpUseEmergencySL       = true;   // Set emergency SL on fill
input double InpEmergencyStopDist    = 5.0;    // Emergency SL distance (price)

input group "=== Aggressive Lot ==="
input bool   InpUseAggressiveLot     = true;   // Grow lot with capital
input double InpBaseLot              = 0.0;    // Base lot (0 = broker min)
input double InpLotPerTier           = 1.0;    // Extra volume-steps per equity tier
input double InpRiskPercentStart     = 50.0;   // Start risk % (aggressive)
input double InpRiskPercentStep      = 5.0;    // Reduce risk % per tier
input double InpRiskPercentFloor     = 15.0;   // Min risk %
input double InpFixedLot             = 0.0;    // Fixed lot override (0 = auto)

input group "=== Runtime ==="
input double InpMaxDailyLossPct      = 80.0;   // Daily loss lock % (0=off)
input int    InpSlippagePoints       = 30;     // Slippage points
input bool   InpAllowBuy             = true;   // Allow BUY
input bool   InpAllowSell            = true;   // Allow SELL

//======================================================================
// HELPERS
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

double CBS_NormPrice(const string symbol, const double price)
{
   return NormalizeDouble(price, CBS_Digits(symbol));
}

double CBS_NormVol(const string symbol, double volume)
{
   const double vmin  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   const double vmax  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   const double vstep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(vstep <= 0.0)
      return vmin;
   volume = MathFloor(volume / vstep + 1e-12) * vstep;
   volume = MathMax(vmin, MathMin(vmax, volume));
   int digits = 2;
   if(vstep < 0.01) digits = 3;
   if(vstep >= 1.0) digits = 0;
   return NormalizeDouble(volume, digits);
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

//--- PH / session time from GMT
datetime CBS_TimeInTZ(const int tzOffsetHours)
{
   return TimeGMT() + tzOffsetHours * 3600;
}

bool CBS_InSessionWindow(const datetime tzTime,
                         const int startH, const int startM,
                         const int endH, const int endM)
{
   MqlDateTime dt;
   TimeToStruct(tzTime, dt);
   const int nowMins  = dt.hour * 60 + dt.min;
   const int startMins = startH * 60 + startM;
   const int endMins   = endH * 60 + endM;

   // Overnight window e.g. 20:00 -> 05:00
   if(startMins <= endMins)
      return (nowMins >= startMins && nowMins < endMins);
   return (nowMins >= startMins || nowMins < endMins);
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
   return CBS_NormVol(symbol, (free * 0.70) / marginOne);
}

double CBS_CalcLot(const string symbol, const ENUM_ORDER_TYPE type, const double refPrice)
{
   if(InpFixedLot > 0.0)
      return CBS_NormVol(symbol, InpFixedLot);

   const double vmin  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   const double vstep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   const double step  = (vstep > 0.0 ? vstep : vmin);
   double lot = (InpBaseLot > 0.0 ? InpBaseLot : vmin);

   if(InpUseAggressiveLot)
   {
      const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      const int tier = CBS_TierIndex(equity);
      lot = lot + (tier * InpLotPerTier * step);

      double riskPct = InpRiskPercentStart - (tier * InpRiskPercentStep);
      if(riskPct < InpRiskPercentFloor)
         riskPct = InpRiskPercentFloor;

      if(InpEmergencyStopDist > 0.0)
      {
         const double riskMoney = equity * (riskPct / 100.0);
         const double lossPerLot = CBS_LossPerLot(symbol, InpEmergencyStopDist);
         if(lossPerLot > 0.0)
            lot = MathMax(lot, riskMoney / lossPerLot);
      }
   }

   lot = MathMin(lot, CBS_MaxLotByMargin(symbol, refPrice, type));
   return CBS_NormVol(symbol, lot);
}

bool CBS_FindPending(const string symbol, const long magic, const long orderType,
                     ulong &ticket, double &price)
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

int CBS_CountPositions(const string symbol, const long magic)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      count++;
   }
   return count;
}

bool CBS_BasketStats(const string symbol, const long magic,
                     int &count, long &side, double &avgPrice, double &totalMoney)
{
   count = 0;
   side = -1;
   avgPrice = 0.0;
   totalMoney = 0.0;
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
      else if(side != typ) return false;

      const double vol = PositionGetDouble(POSITION_VOLUME);
      const double op  = PositionGetDouble(POSITION_PRICE_OPEN);
      volSum += vol;
      pxVol  += op * vol;
      totalMoney += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
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
// GLOBALS
//======================================================================
CTrade          g_trade;
string          g_symbol;
ENUM_TIMEFRAMES g_tf;                 // attached chart TF only
datetime        g_candleTime = 0;
double          g_candleOpen = 0.0;
int             g_color = 0;          // +1 green, -1 red, 0 flat
bool            g_sessionOn = false;
bool            g_dailyLock = false;
double          g_dayStartEq = 0.0;
int             g_dayStamp = -1;
bool            g_hadPosition = false;
bool            g_reentryMode = false;          // after close: arm immediately
bool            g_useReentryGap = false;        // pending distance = reentry gap until filled

//======================================================================
// FORWARD DECLS
//======================================================================
void UpdateSession();
void UpdateDailyLock();
void RefreshCandle(const bool force);
void ApplyEmergencySL();
void ManageBasket();
void ManageEntries();
void EnsureSellStop_TrailUpOnly(const double targetPrice);
void EnsureBuyStop_TrailDownOnly(const double targetPrice);
double PendingTargetSell(const bool reentry);
double PendingTargetBuy(const bool reentry);

//======================================================================
int OnInit()
{
   g_symbol = _Symbol;
   g_tf     = (ENUM_TIMEFRAMES)_Period; // ANY attached timeframe

   if(!SymbolSelect(g_symbol, true))
   {
      Print("ERROR: SymbolSelect failed for ", g_symbol);
      return INIT_FAILED;
   }
   if(InpBufferDistance < 0.0 || InpPendingOffset < 0.0 || InpReentryGap < 0.0 ||
      InpBurstProfit <= 0.0 || InpMaxBasket < 1)
   {
      Print("ERROR: invalid entry/burst inputs");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpSessionStartHour < 0 || InpSessionStartHour > 23 ||
      InpSessionEndHour < 0 || InpSessionEndHour > 23 ||
      InpSessionStartMinute < 0 || InpSessionStartMinute > 59 ||
      InpSessionEndMinute < 0 || InpSessionEndMinute > 59)
   {
      Print("ERROR: invalid session clock inputs");
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

   UpdateSession();
   RefreshCandle(true);

   PrintFormat("ColorBurstScalper ready | %s | TF=%s | session PH %02d:%02d-%02d:%02d (UTC+%d) | buffer=%.5f reentry=%.5f burst=%.5f",
               g_symbol, EnumToString(g_tf),
               InpSessionStartHour, InpSessionStartMinute,
               InpSessionEndHour, InpSessionEndMinute,
               InpSessionTZOffsetHours,
               InpBufferDistance, InpReentryGap, InpBurstProfit);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
}

void OnTick()
{
   if(!CBS_TradeAllowed(g_symbol))
      return;

   UpdateDailyLock();
   UpdateSession();
   RefreshCandle(false);

   // Always manage open risk tools
   ApplyEmergencySL();
   ManageBasket();

   // Detect close → enable re-entry mode
   const bool hasPos = (CBS_CountPositions(g_symbol, InpMagic) > 0);
   if(g_hadPosition && !hasPos)
   {
      g_reentryMode = true;
      g_useReentryGap = false;
      CBS_CancelAllPending(g_trade, g_symbol, InpMagic);
      Print("Basket/position closed → re-entry mode ON");
   }
   if(hasPos)
      g_useReentryGap = false; // filled — burst add-ons use normal offset
   g_hadPosition = hasPos;

   // Session / daily lock: no new entries
   if(!g_sessionOn || g_dailyLock)
   {
      CBS_CancelAllPending(g_trade, g_symbol, InpMagic);
      return;
   }

   ManageEntries();
}

//======================================================================
void UpdateSession()
{
   if(!InpUseSessionFilter)
   {
      g_sessionOn = true;
      return;
   }
   const datetime tzNow = CBS_TimeInTZ(InpSessionTZOffsetHours);
   g_sessionOn = CBS_InSessionWindow(tzNow,
                                     InpSessionStartHour, InpSessionStartMinute,
                                     InpSessionEndHour, InpSessionEndMinute);
}

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
   // IMPORTANT: uses attached chart TF only (g_tf = _Period)
   const datetime t = iTime(g_symbol, g_tf, 0);
   const double o = iOpen(g_symbol, g_tf, 0);
   if(t == 0 || o <= 0.0)
      return;

   if(force || t != g_candleTime)
   {
      if(!force && g_candleTime != 0)
      {
         CBS_CancelAllPending(g_trade, g_symbol, InpMagic);
         g_reentryMode = false;   // new candle → first-arm from open again
         g_useReentryGap = false;
         PrintFormat("New candle TF=%s %s open=%.5f — reset pendings/first-arm",
                     EnumToString(g_tf), TimeToString(t, TIME_DATE|TIME_MINUTES), o);
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
   return ((g_candleOpen - SymbolInfoDouble(g_symbol, SYMBOL_BID)) >= InpBufferDistance);
}

bool BufferReadyBuy()
{
   return ((SymbolInfoDouble(g_symbol, SYMBOL_ASK) - g_candleOpen) >= InpBufferDistance);
}

double PendingTargetSell(const bool reentry)
{
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double gap = (reentry ? InpReentryGap : InpPendingOffset);
   const double minDist = MathMax(gap, CBS_StopsDist(g_symbol));
   // Re-entry: user example current 4401 -> pending 4400 (gap 1.0)
   // First arm after buffer: pending also offset below market
   return CBS_NormPrice(g_symbol, bid - minDist);
}

double PendingTargetBuy(const bool reentry)
{
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double gap = (reentry ? InpReentryGap : InpPendingOffset);
   const double minDist = MathMax(gap, CBS_StopsDist(g_symbol));
   return CBS_NormPrice(g_symbol, ask + minDist);
}

//======================================================================
// BASKET
//======================================================================
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
      if(PositionGetDouble(POSITION_SL) > 0.0) continue;

      const long typ = PositionGetInteger(POSITION_TYPE);
      const double op = PositionGetDouble(POSITION_PRICE_OPEN);
      const double tp = PositionGetDouble(POSITION_TP);
      const double em = (typ == POSITION_TYPE_BUY)
                        ? CBS_NormPrice(g_symbol, op - InpEmergencyStopDist)
                        : CBS_NormPrice(g_symbol, op + InpEmergencyStopDist);
      g_trade.PositionModify(t, em, tp);
   }
}

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
   if(side == POSITION_TYPE_BUY)       favor = bid - avg;
   else if(side == POSITION_TYPE_SELL) favor = avg - ask;
   else return;

   // Burst TP — small profit close whole basket
   if(favor >= InpBurstProfit)
   {
      PrintFormat("BURST TP favor=%.5f money=%.2f positions=%d — close all", favor, money, count);
      CBS_CloseBasket(g_trade, g_symbol, InpMagic);
      CBS_CancelAllPending(g_trade, g_symbol, InpMagic);
      return;
   }

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
         double newSL = CBS_NormPrice(g_symbol, bid - InpBasketTrailGap);
         const double floorSL = CBS_NormPrice(g_symbol, avg + (InpBasketTrailStart - InpBasketTrailGap));
         if(newSL < floorSL) newSL = floorSL;
         if(newSL > openPx && (sl <= 0.0 || newSL > sl + CBS_Point(g_symbol) * 0.5))
         {
            if(bid - newSL >= stops)
               g_trade.PositionModify(t, newSL, tp);
         }
      }
      else
      {
         double newSL = CBS_NormPrice(g_symbol, ask + InpBasketTrailGap);
         const double floorSL = CBS_NormPrice(g_symbol, avg - (InpBasketTrailStart - InpBasketTrailGap));
         if(newSL > floorSL) newSL = floorSL;
         if(newSL < openPx && (sl <= 0.0 || newSL < sl - CBS_Point(g_symbol) * 0.5))
         {
            if(newSL - ask >= stops)
               g_trade.PositionModify(t, newSL, tp);
         }
      }
   }
}

//======================================================================
// ENTRIES
//======================================================================
void ManageEntries()
{
   const int totalPos = CBS_CountPositions(g_symbol, InpMagic);
   const bool canAdd = (totalPos < InpMaxBasket);

   //----- RED → SELL only -----
   if(g_color < 0 && InpAllowSell)
   {
      CBS_CancelPendingType(g_trade, g_symbol, InpMagic, ORDER_TYPE_BUY_STOP);

      bool armed = false;
      if(g_reentryMode || totalPos > 0)
         armed = true; // re-entry / burst add-on: no need re-check open-buffer
      else
         armed = BufferReadySell(); // first arm of candle

      if(armed && canAdd)
      {
         const bool useReentryGap = (g_reentryMode && totalPos == 0);
         const double target = PendingTargetSell(useReentryGap);
         EnsureSellStop_TrailUpOnly(target);
         // once pending is working after close, keep trailing with market offset,
         // but initial place used reentry gap; subsequent modifies use desired from helper
      }
      else if(!canAdd)
         CBS_CancelPendingType(g_trade, g_symbol, InpMagic, ORDER_TYPE_SELL_STOP);

      return;
   }

   //----- GREEN → BUY only -----
   if(g_color > 0 && InpAllowBuy)
   {
      CBS_CancelPendingType(g_trade, g_symbol, InpMagic, ORDER_TYPE_SELL_STOP);

      bool armed = false;
      if(g_reentryMode || totalPos > 0)
         armed = true;
      else
         armed = BufferReadyBuy();

      if(armed && canAdd)
      {
         const bool useReentryGap = (g_reentryMode && totalPos == 0);
         const double target = PendingTargetBuy(useReentryGap);
         EnsureBuyStop_TrailDownOnly(target);
      }
      else if(!canAdd)
         CBS_CancelPendingType(g_trade, g_symbol, InpMagic, ORDER_TYPE_BUY_STOP);

      return;
   }

   // Flat / not allowed
   CBS_CancelAllPending(g_trade, g_symbol, InpMagic);
}

// SELL STOP below market; trail UP only (never down)
void EnsureSellStop_TrailUpOnly(const double /*ignoredInitial*/)
{
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double stops = CBS_StopsDist(g_symbol);
   ulong ticket = 0;
   double cur = 0.0;
   const bool exists = CBS_FindPending(g_symbol, InpMagic, ORDER_TYPE_SELL_STOP, ticket, cur);

   // Re-entry pending keeps ReentryGap distance; first-arm/burst uses PendingOffset
   const bool useGap = (g_useReentryGap || (g_reentryMode && CBS_CountPositions(g_symbol, InpMagic) == 0));
   double desired = PendingTargetSell(useGap);
   const double minDist = MathMax(useGap ? InpReentryGap : InpPendingOffset, stops);
   if(desired >= bid)
      desired = CBS_NormPrice(g_symbol, bid - minDist);

   if(exists)
   {
      if(cur >= bid)
      {
         g_trade.OrderDelete(ticket);
      }
      else
      {
         // one-way UP only — follows only when price rises
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
      const double lot = CBS_CalcLot(g_symbol, ORDER_TYPE_SELL_STOP, desired);
      if(!g_trade.SellStop(lot, desired, g_symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "CBS SELL"))
         Print("SELL_STOP place fail: ", g_trade.ResultRetcodeDescription());
      else
      {
         if(g_reentryMode && CBS_CountPositions(g_symbol, InpMagic) == 0)
         {
            g_useReentryGap = true;  // keep 1.0 gap while trailing up
            g_reentryMode = false;
         }
      }
   }
}

// BUY STOP above market; trail DOWN only (never up)
void EnsureBuyStop_TrailDownOnly(const double /*ignoredInitial*/)
{
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double stops = CBS_StopsDist(g_symbol);
   ulong ticket = 0;
   double cur = 0.0;
   const bool exists = CBS_FindPending(g_symbol, InpMagic, ORDER_TYPE_BUY_STOP, ticket, cur);

   const bool useGap = (g_useReentryGap || (g_reentryMode && CBS_CountPositions(g_symbol, InpMagic) == 0));
   double desired = PendingTargetBuy(useGap);
   const double minDist = MathMax(useGap ? InpReentryGap : InpPendingOffset, stops);
   if(desired <= ask)
      desired = CBS_NormPrice(g_symbol, ask + minDist);

   if(exists)
   {
      if(cur <= ask)
      {
         g_trade.OrderDelete(ticket);
      }
      else
      {
         // one-way DOWN only
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
      const double lot = CBS_CalcLot(g_symbol, ORDER_TYPE_BUY_STOP, desired);
      if(!g_trade.BuyStop(lot, desired, g_symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "CBS BUY"))
         Print("BUY_STOP place fail: ", g_trade.ResultRetcodeDescription());
      else
      {
         if(g_reentryMode && CBS_CountPositions(g_symbol, InpMagic) == 0)
         {
            g_useReentryGap = true;
            g_reentryMode = false;
         }
      }
   }
}

//+------------------------------------------------------------------+
