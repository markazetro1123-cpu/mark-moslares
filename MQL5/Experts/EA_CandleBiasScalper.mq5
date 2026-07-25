//+------------------------------------------------------------------+
//| EA_CandleBiasScalper.mq5                                         |
//| Candle-Bias One-Way Trailing Pending Scalper                     |
//| XAUUSD / US30 | Any timeframe | Deriv / Tickmill compatible      |
//+------------------------------------------------------------------+
#property copyright "Mark Moslares"
#property link      "https://github.com/markazetro1123-cpu/mark-moslares"
#property version   "1.00"
#property description "Candle bias + one-way trailing pendings + flip + secure/trail + smart risk"
#property strict

#include <Trade/Trade.mqh>
#include <CBR_Utils.mqh>
#include <CBR_Risk.mqh>

input group "=== Entry ==="
input double InpBufferDistance     = 1.0;      // Buffer from candle open (price)
input double InpPendingOffset      = 0.2;      // Pending offset from price
input long   InpMagic              = 260715;   // Magic number

input group "=== Profit ==="
input double InpSecureProfit       = 0.2;      // Secure floor (price)
input double InpTrailDistance      = 0.1;      // Trail distance from current price

input group "=== Risk ==="
input bool   InpUseSmartRisk       = true;     // Smart risk manager
input double InpFixedLot           = 0.0;      // Fixed lot (0 = smart/min)
input double InpEmergencyStopDist  = 5.0;      // Emergency SL distance (price)
input double InpMaxDailyLossPct    = 80.0;     // Max daily loss % (pause)

input group "=== Runtime ==="
input int    InpSlippagePoints     = 30;       // Max slippage (points)
input bool   InpAllowBuy           = true;     // Allow BUY side
input bool   InpAllowSell          = true;     // Allow SELL side

CTrade          g_trade;
string          g_symbol;
ENUM_TIMEFRAMES g_tf;
datetime        g_candleOpenTime = 0;
double          g_candleOpen     = 0.0;
int             g_bias           = 0;  // +1 buy, -1 sell, 0 none
bool            g_dailyLocked    = false;
double          g_dayStartEquity = 0.0;
int             g_dayStamp       = -1;

//+------------------------------------------------------------------+
int OnInit()
{
   g_symbol = _Symbol;
   g_tf     = (ENUM_TIMEFRAMES)_Period;

   if(!SymbolSelect(g_symbol, true))
   {
      Print("ERROR: SymbolSelect failed for ", g_symbol);
      return INIT_FAILED;
   }
   if(InpBufferDistance < 0.0 || InpPendingOffset < 0.0 ||
      InpSecureProfit < 0.0 || InpTrailDistance < 0.0)
   {
      Print("ERROR: distances must be >= 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   ENUM_ORDER_TYPE_FILLING filling;
   CBR_SelectFilling(g_symbol, filling);
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFilling(filling);
   g_trade.SetAsyncMode(false);

   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   g_dayStamp = dt.day_of_year;

   RefreshCandleContext(true);
   PrintFormat("CandleBiasScalper ready | %s | %s | buffer=%.5f offset=%.5f",
               g_symbol, EnumToString(g_tf), InpBufferDistance, InpPendingOffset);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(!CBR_IsTradeAllowed(g_symbol))
      return;

   UpdateDailyLock();
   if(g_dailyLocked)
      return;

   RefreshCandleContext(false);

   ulong posTicket = 0;
   long  posType   = -1;
   const bool hasPos = CBR_GetOurPosition(g_symbol, InpMagic, posTicket, posType);

   // Enforce one position (hedging brokers)
   EnforceSinglePosition();

   if(hasPos)
   {
      ManageOpenPosition(posTicket, posType);
      ManageCounterPendingWhileInPosition(posType);
      return;
   }

   ManageEntryPendings();
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   EnforceSinglePosition();
}

//+------------------------------------------------------------------+
void EnforceSinglePosition()
{
   ulong buyTicket = 0, sellTicket = 0;
   datetime buyTime = 0, sellTime = 0;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      const long typ = PositionGetInteger(POSITION_TYPE);
      const datetime tm = (datetime)PositionGetInteger(POSITION_TIME);
      if(typ == POSITION_TYPE_BUY)
      {
         if(buyTicket == 0 || tm >= buyTime)
         {
            buyTicket = t;
            buyTime = tm;
         }
      }
      else if(typ == POSITION_TYPE_SELL)
      {
         if(sellTicket == 0 || tm >= sellTime)
         {
            sellTicket = t;
            sellTime = tm;
         }
      }
   }

   if(buyTicket > 0 && sellTicket > 0)
   {
      // Newest wins (flip)
      if(buyTime >= sellTime)
      {
         g_trade.PositionClose(sellTicket);
         CBR_CancelPendingByType(g_trade, g_symbol, InpMagic, ORDER_TYPE_BUY_STOP);
         Print("FLIP: SELL closed, BUY kept");
      }
      else
      {
         g_trade.PositionClose(buyTicket);
         CBR_CancelPendingByType(g_trade, g_symbol, InpMagic, ORDER_TYPE_SELL_STOP);
         Print("FLIP: BUY closed, SELL kept");
      }
   }
}

//+------------------------------------------------------------------+
void UpdateDailyLock()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != g_dayStamp)
   {
      g_dayStamp = dt.day_of_year;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_dailyLocked = false;
   }
   if(InpMaxDailyLossPct <= 0.0 || g_dayStartEquity <= 0.0)
      return;

   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   const double ddPct = ((g_dayStartEquity - eq) / g_dayStartEquity) * 100.0;
   if(ddPct >= InpMaxDailyLossPct)
   {
      if(!g_dailyLocked)
      {
         PrintFormat("Daily loss lock: %.2f%%", ddPct);
         CBR_CancelAllPending(g_trade, g_symbol, InpMagic);
      }
      g_dailyLocked = true;
   }
}

//+------------------------------------------------------------------+
void RefreshCandleContext(const bool force)
{
   const datetime t = iTime(g_symbol, g_tf, 0);
   const double   o = iOpen(g_symbol, g_tf, 0);
   if(t == 0 || o <= 0.0)
      return;

   if(force || t != g_candleOpenTime)
   {
      if(!force && g_candleOpenTime != 0)
      {
         CBR_CancelAllPending(g_trade, g_symbol, InpMagic);
         PrintFormat("New candle %s open=%.5f — pending reset",
                     TimeToString(t, TIME_DATE|TIME_MINUTES), o);
      }
      g_candleOpenTime = t;
      g_candleOpen = o;
   }
   else
      g_candleOpen = o;

   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   if(bid < g_candleOpen)      g_bias = -1;
   else if(ask > g_candleOpen) g_bias = +1;
   else                        g_bias = 0;
}

//+------------------------------------------------------------------+
bool BufferPassedSell()
{
   return ((g_candleOpen - SymbolInfoDouble(g_symbol, SYMBOL_BID)) >= InpBufferDistance);
}

//+------------------------------------------------------------------+
bool BufferPassedBuy()
{
   return ((SymbolInfoDouble(g_symbol, SYMBOL_ASK) - g_candleOpen) >= InpBufferDistance);
}

//+------------------------------------------------------------------+
double ComputeLot(const ENUM_ORDER_TYPE marginType, const double refPrice)
{
   if(InpFixedLot > 0.0)
      return CBR_NormalizeVolume(g_symbol, InpFixedLot);
   if(!InpUseSmartRisk)
      return SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);

   CBRRiskPlan plan = CBR_BuildRiskPlan(g_symbol, InpEmergencyStopDist, marginType, refPrice);
   return plan.lot;
}

//+------------------------------------------------------------------+
void ManageEntryPendings()
{
   // SELL priority (red / down)
   if(g_bias < 0 && InpAllowSell && BufferPassedSell())
   {
      EnsureSellStop_OneWayUp();
      if(InpAllowBuy)
         EnsureBuyStop_OneWayDown();
      else
         CBR_CancelPendingByType(g_trade, g_symbol, InpMagic, ORDER_TYPE_BUY_STOP);
      return;
   }

   // BUY priority (green / up)
   if(g_bias > 0 && InpAllowBuy && BufferPassedBuy())
   {
      EnsureBuyStop_OneWayDown(); // places if none; trails down only if price later falls
      if(InpAllowSell)
         EnsureSellStop_OneWayUp();
      else
         CBR_CancelPendingByType(g_trade, g_symbol, InpMagic, ORDER_TYPE_SELL_STOP);
      return;
   }

   // Not armed: still maintain one-way ratchet on existing pendings
   ulong ticket; double px;
   if(CBR_FindPending(g_symbol, InpMagic, ORDER_TYPE_BUY_STOP, ticket, px))
      EnsureBuyStop_OneWayDown();
   if(CBR_FindPending(g_symbol, InpMagic, ORDER_TYPE_SELL_STOP, ticket, px))
      EnsureSellStop_OneWayUp();
}

//+------------------------------------------------------------------+
void ManageCounterPendingWhileInPosition(const long posType)
{
   if(posType == POSITION_TYPE_SELL)
   {
      // Counter BUY only
      CBR_CancelPendingByType(g_trade, g_symbol, InpMagic, ORDER_TYPE_SELL_STOP);
      if(InpAllowBuy)
         EnsureBuyStop_OneWayDown();
   }
   else if(posType == POSITION_TYPE_BUY)
   {
      CBR_CancelPendingByType(g_trade, g_symbol, InpMagic, ORDER_TYPE_BUY_STOP);
      if(InpAllowSell)
         EnsureSellStop_OneWayUp();
   }
}

//+------------------------------------------------------------------+
// BUY STOP above Ask | ratchet DOWN only
//+------------------------------------------------------------------+
void EnsureBuyStop_OneWayDown()
{
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double minDist = MathMax(InpPendingOffset, CBR_StopsLevelDistance(g_symbol));
   const double desired = CBR_NormalizePrice(g_symbol, ask + minDist);

   ulong ticket = 0;
   double cur = 0.0;
   if(CBR_FindPending(g_symbol, InpMagic, ORDER_TYPE_BUY_STOP, ticket, cur))
   {
      // Must remain above Ask; if invalid, delete and re-place
      if(cur <= ask)
      {
         g_trade.OrderDelete(ticket);
      }
      else if(desired < cur - CBR_Point(g_symbol) * 0.5)
      {
         if(!g_trade.OrderModify(ticket, desired, 0.0, 0.0, ORDER_TIME_GTC, 0))
            Print("BUY_STOP modify fail: ", g_trade.ResultRetcodeDescription());
      }
      // never raise
      return;
   }

   const double lot = ComputeLot(ORDER_TYPE_BUY_STOP, desired);
   if(!g_trade.BuyStop(lot, desired, g_symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "CBR BUY_STOP"))
      Print("BUY_STOP place fail: ", g_trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
// SELL STOP below Bid | ratchet UP only
//+------------------------------------------------------------------+
void EnsureSellStop_OneWayUp()
{
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double minDist = MathMax(InpPendingOffset, CBR_StopsLevelDistance(g_symbol));
   const double desired = CBR_NormalizePrice(g_symbol, bid - minDist);

   ulong ticket = 0;
   double cur = 0.0;
   if(CBR_FindPending(g_symbol, InpMagic, ORDER_TYPE_SELL_STOP, ticket, cur))
   {
      if(cur >= bid)
      {
         g_trade.OrderDelete(ticket);
      }
      else if(desired > cur + CBR_Point(g_symbol) * 0.5)
      {
         if(!g_trade.OrderModify(ticket, desired, 0.0, 0.0, ORDER_TIME_GTC, 0))
            Print("SELL_STOP modify fail: ", g_trade.ResultRetcodeDescription());
      }
      // never lower
      return;
   }

   const double lot = ComputeLot(ORDER_TYPE_SELL_STOP, desired);
   if(!g_trade.SellStop(lot, desired, g_symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "CBR SELL_STOP"))
      Print("SELL_STOP place fail: ", g_trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
void ManageOpenPosition(const ulong ticket, const long posType)
{
   if(!PositionSelectByTicket(ticket))
      return;

   const double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   const double sl        = PositionGetDouble(POSITION_SL);
   const double tp        = PositionGetDouble(POSITION_TP);
   const double bid       = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask       = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double stopsDist = CBR_StopsLevelDistance(g_symbol);

   // Emergency SL if missing
   if(sl <= 0.0 && InpEmergencyStopDist > 0.0)
   {
      double emSL = (posType == POSITION_TYPE_BUY)
                    ? CBR_NormalizePrice(g_symbol, openPrice - InpEmergencyStopDist)
                    : CBR_NormalizePrice(g_symbol, openPrice + InpEmergencyStopDist);
      g_trade.PositionModify(ticket, emSL, tp);
      return;
   }

   if(posType == POSITION_TYPE_BUY)
   {
      if(bid - openPrice < InpSecureProfit)
         return;

      double newSL = CBR_NormalizePrice(g_symbol, bid - InpTrailDistance);
      const double floorSL = CBR_NormalizePrice(g_symbol, openPrice + (InpSecureProfit - InpTrailDistance));
      if(newSL < floorSL)
         newSL = floorSL;

      if(newSL > openPrice && (sl <= 0.0 || newSL > sl + CBR_Point(g_symbol) * 0.5))
      {
         if(bid - newSL >= stopsDist)
            g_trade.PositionModify(ticket, newSL, tp);
      }
   }
   else if(posType == POSITION_TYPE_SELL)
   {
      if(openPrice - ask < InpSecureProfit)
         return;

      double newSL = CBR_NormalizePrice(g_symbol, ask + InpTrailDistance);
      const double floorSL = CBR_NormalizePrice(g_symbol, openPrice - (InpSecureProfit - InpTrailDistance));
      if(newSL > floorSL)
         newSL = floorSL;

      if(newSL < openPrice && (sl <= 0.0 || newSL < sl - CBR_Point(g_symbol) * 0.5))
      {
         if(newSL - ask >= stopsDist)
            g_trade.PositionModify(ticket, newSL, tp);
      }
   }
}

//+------------------------------------------------------------------+
