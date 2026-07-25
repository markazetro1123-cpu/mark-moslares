//+------------------------------------------------------------------+
//| EA_IrsadStyleScalper.mq5                                         |
//| Full Irsad-style XAUUSD pending scalper (single file)            |
//|                                                                  |
//| - Candle-open bias                                               |
//| - Buffer arming                                                  |
//| - BuyStop above / SellStop below                                 |
//| - One-way trailing pending (BUY down-only, SELL up-only)         |
//| - Priority + counter pending                                     |
//| - Max 1 position + flip on counter fill                          |
//| - Secure profit then trail                                       |
//| - Aggressive lot growth with capital                             |
//| - Works on ANY attached timeframe                                |
//+------------------------------------------------------------------+
#property copyright "Mark Moslares"
#property link      "https://github.com/markazetro1123-cpu/mark-moslares"
#property version   "1.00"
#property description "Full Irsad-style: bias+buffer+one-way pendings+counter+flip+secure/trail"

#include <Trade/Trade.mqh>

//======================================================================
// INPUTS
//======================================================================
input group "=== Entry (Irsad) ==="
input double InpBufferDistance      = 1.0;     // Buffer from candle open (price)
input double InpPendingOffset       = 0.2;     // Pending gap from market
input bool   InpUseCounterPending   = true;    // Place counter pending (Irsad-style)
input bool   InpAllowFlip           = true;    // Flip when counter fills
input long   InpMagic               = 260732;  // Magic number

input group "=== Profit ==="
input double InpSecureProfit        = 0.30;    // Secure floor (price)
input double InpTrailDistance       = 0.15;    // Trail distance from price
input double InpEmergencyStopDist   = 5.0;     // Emergency SL if missing (price)

input group "=== Aggressive Lot ==="
input bool   InpUseAggressiveLot    = true;    // Grow lot with capital
input double InpBaseLot             = 0.0;     // Base lot (0 = broker min)
input double InpLotPerTier          = 1.0;     // Extra volume-steps per tier
input double InpRiskPercentStart    = 50.0;    // Start risk % vs emergency SL
input double InpRiskPercentStep     = 5.0;     // Reduce risk % per tier
input double InpRiskPercentFloor    = 15.0;    // Min risk %
input double InpFixedLot            = 0.0;     // Fixed lot override (0 = auto)

input group "=== Session (optional) ==="
input bool   InpUseSessionFilter    = false;   // Off = trade all day (pure Irsad)
input int    InpSessionTZOffsetHrs  = 8;       // PH = 8
input int    InpSessionStartHour    = 20;      // 8PM PH
input int    InpSessionStartMinute  = 0;
input int    InpSessionEndHour      = 5;       // 5AM PH
input int    InpSessionEndMinute    = 0;

input group "=== Runtime ==="
input double InpMaxDailyLossPct     = 80.0;    // Daily lock % (0=off)
input double InpMaxSpreadPrice      = 0.0;     // Skip if spread > this (0=off)
input int    InpSlippagePoints      = 40;      // Deviation points
input bool   InpAllowBuy            = true;
input bool   InpAllowSell           = true;

//======================================================================
// HELPERS
//======================================================================
double IRS_Point(const string s)
{
   const double p = SymbolInfoDouble(s, SYMBOL_POINT);
   return (p > 0.0 ? p : _Point);
}

int IRS_Digits(const string s)
{
   return (int)SymbolInfoInteger(s, SYMBOL_DIGITS);
}

double IRS_NormPrice(const string s, const double price)
{
   return NormalizeDouble(price, IRS_Digits(s));
}

double IRS_NormVol(const string s, double vol)
{
   const double vmin  = SymbolInfoDouble(s, SYMBOL_VOLUME_MIN);
   const double vmax  = SymbolInfoDouble(s, SYMBOL_VOLUME_MAX);
   const double vstep = SymbolInfoDouble(s, SYMBOL_VOLUME_STEP);
   if(vstep <= 0.0) return vmin;
   vol = MathFloor(vol / vstep + 1e-12) * vstep;
   vol = MathMax(vmin, MathMin(vmax, vol));
   int d = 2;
   if(vstep < 0.01) d = 3;
   if(vstep >= 1.0) d = 0;
   return NormalizeDouble(vol, d);
}

bool IRS_SelectFilling(const string s, ENUM_ORDER_TYPE_FILLING &filling)
{
   const int modes = (int)SymbolInfoInteger(s, SYMBOL_FILLING_MODE);
   if((modes & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) { filling = ORDER_FILLING_IOC; return true; }
   if((modes & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) { filling = ORDER_FILLING_FOK; return true; }
   filling = ORDER_FILLING_RETURN;
   return true;
}

double IRS_StopsDist(const string s)
{
   const int stops  = (int)SymbolInfoInteger(s, SYMBOL_TRADE_STOPS_LEVEL);
   const int freeze = (int)SymbolInfoInteger(s, SYMBOL_TRADE_FREEZE_LEVEL);
   return MathMax(stops, freeze) * IRS_Point(s);
}

bool IRS_TradeOk(const string s)
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;
   if(SymbolInfoInteger(s, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED) return false;
   return true;
}

bool IRS_InSession()
{
   if(!InpUseSessionFilter) return true;
   const datetime tz = TimeGMT() + InpSessionTZOffsetHrs * 3600;
   MqlDateTime dt;
   TimeToStruct(tz, dt);
   const int now = dt.hour * 60 + dt.min;
   const int a = InpSessionStartHour * 60 + InpSessionStartMinute;
   const int b = InpSessionEndHour * 60 + InpSessionEndMinute;
   if(a <= b) return (now >= a && now < b);
   return (now >= a || now < b);
}

int IRS_Tier(const double eq)
{
   if(eq < 50.0) return 0;
   if(eq < 100.0) return 1;
   if(eq < 200.0) return 2;
   if(eq < 350.0) return 3;
   if(eq < 500.0) return 4;
   if(eq < 750.0) return 5;
   if(eq < 1000.0) return 6;
   return 7;
}

double IRS_LossPerLot(const string s, const double dist)
{
   if(dist <= 0.0) return 0.0;
   const double ts = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_SIZE);
   const double tv = SymbolInfoDouble(s, SYMBOL_TRADE_TICK_VALUE);
   if(ts <= 0.0 || tv <= 0.0) return 0.0;
   return (dist / ts) * tv;
}

double IRS_MaxLotMargin(const string s, const double price, const ENUM_ORDER_TYPE type)
{
   const double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   const double vmin = SymbolInfoDouble(s, SYMBOL_VOLUME_MIN);
   if(free <= 0.0) return vmin;
   double m1 = 0.0;
   if(!OrderCalcMargin(type, s, 1.0, price, m1) || m1 <= 0.0)
   {
      double mm = 0.0;
      if(!OrderCalcMargin(type, s, vmin, price, mm) || mm <= 0.0) return vmin;
      m1 = mm / vmin;
   }
   return IRS_NormVol(s, (free * 0.70) / m1);
}

double IRS_CalcLot(const string s, const ENUM_ORDER_TYPE type, const double price)
{
   if(InpFixedLot > 0.0)
      return IRS_NormVol(s, InpFixedLot);

   const double vmin  = SymbolInfoDouble(s, SYMBOL_VOLUME_MIN);
   const double vstep = SymbolInfoDouble(s, SYMBOL_VOLUME_STEP);
   const double step  = (vstep > 0.0 ? vstep : vmin);
   double lot = (InpBaseLot > 0.0 ? InpBaseLot : vmin);

   if(InpUseAggressiveLot)
   {
      const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
      const int tier = IRS_Tier(eq);
      lot = lot + tier * InpLotPerTier * step;

      double riskPct = InpRiskPercentStart - tier * InpRiskPercentStep;
      if(riskPct < InpRiskPercentFloor) riskPct = InpRiskPercentFloor;

      if(InpEmergencyStopDist > 0.0)
      {
         const double loss = IRS_LossPerLot(s, InpEmergencyStopDist);
         if(loss > 0.0)
            lot = MathMax(lot, (eq * riskPct / 100.0) / loss);
      }
   }

   lot = MathMin(lot, IRS_MaxLotMargin(s, price, type));
   return IRS_NormVol(s, lot);
}

bool IRS_FindPending(const string s, const long magic, const long type, ulong &ticket, double &price)
{
   ticket = 0; price = 0.0;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      const ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL) != s) continue;
      if(OrderGetInteger(ORDER_MAGIC) != magic) continue;
      if(OrderGetInteger(ORDER_TYPE) != type) continue;
      ticket = t;
      price = OrderGetDouble(ORDER_PRICE_OPEN);
      return true;
   }
   return false;
}

bool IRS_CancelType(CTrade &tr, const string s, const long magic, const long type)
{
   bool ok = true;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      const ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL) != s) continue;
      if(OrderGetInteger(ORDER_MAGIC) != magic) continue;
      if(OrderGetInteger(ORDER_TYPE) != type) continue;
      if(!tr.OrderDelete(t)) ok = false;
   }
   return ok;
}

bool IRS_CancelAllPending(CTrade &tr, const string s, const long magic)
{
   bool ok = true;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      const ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL) != s) continue;
      if(OrderGetInteger(ORDER_MAGIC) != magic) continue;
      const long typ = OrderGetInteger(ORDER_TYPE);
      if(typ == ORDER_TYPE_BUY || typ == ORDER_TYPE_SELL) continue;
      if(!tr.OrderDelete(t)) ok = false;
   }
   return ok;
}

bool IRS_GetPosition(const string s, const long magic, ulong &ticket, long &type)
{
   ticket = 0; type = -1;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != s) continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic) continue;
      ticket = t;
      type = PositionGetInteger(POSITION_TYPE);
      return true;
   }
   return false;
}

//======================================================================
// GLOBALS
//======================================================================
CTrade          g_trade;
string          g_symbol;
ENUM_TIMEFRAMES g_tf;
datetime        g_candleTime = 0;
double          g_candleOpen = 0.0;
int             g_bias = 0; // +1 buy, -1 sell
bool            g_dailyLock = false;
double          g_dayStartEq = 0.0;
int             g_dayStamp = -1;

void RefreshCandle(const bool force);
void UpdateDailyLock();
void EnforceFlipOrSingle();
void ManageOpenPosition(const ulong ticket, const long posType);
void ManageEntries();
void EnsureBuyStop_TrailDown();
void EnsureSellStop_TrailUp();
double CalcLot(const ENUM_ORDER_TYPE t, const double px);

//======================================================================
int OnInit()
{
   g_symbol = _Symbol;
   g_tf = (ENUM_TIMEFRAMES)_Period;

   if(!SymbolSelect(g_symbol, true))
   {
      Print("IRS ERROR: SymbolSelect failed");
      return INIT_FAILED;
   }
   if(InpBufferDistance < 0.0 || InpPendingOffset < 0.0 ||
      InpSecureProfit < 0.0 || InpTrailDistance < 0.0)
   {
      Print("IRS ERROR: invalid distances");
      return INIT_PARAMETERS_INCORRECT;
   }

   ENUM_ORDER_TYPE_FILLING fill;
   IRS_SelectFilling(g_symbol, fill);
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFilling(fill);
   g_trade.SetAsyncMode(false);

   g_dayStartEq = AccountInfoDouble(ACCOUNT_EQUITY);
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   g_dayStamp = dt.day_of_year;

   RefreshCandle(true);
   PrintFormat("IrsadStyleScalper ready | %s | TF=%s | buffer=%.5f offset=%.5f counter=%s flip=%s",
               g_symbol, EnumToString(g_tf), InpBufferDistance, InpPendingOffset,
               (InpUseCounterPending ? "ON" : "OFF"),
               (InpAllowFlip ? "ON" : "OFF"));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason) {}

void OnTick()
{
   if(!IRS_TradeOk(g_symbol)) return;

   UpdateDailyLock();
   if(g_dailyLock) return;

   if(!IRS_InSession())
   {
      IRS_CancelAllPending(g_trade, g_symbol, InpMagic);
      // still manage open position if any
      ulong t; long typ;
      if(IRS_GetPosition(g_symbol, InpMagic, t, typ))
         ManageOpenPosition(t, typ);
      return;
   }

   if(InpMaxSpreadPrice > 0.0)
   {
      const double sp = SymbolInfoDouble(g_symbol, SYMBOL_ASK) - SymbolInfoDouble(g_symbol, SYMBOL_BID);
      if(sp > InpMaxSpreadPrice)
         return;
   }

   RefreshCandle(false);
   EnforceFlipOrSingle();

   ulong posTicket = 0;
   long  posType = -1;
   const bool hasPos = IRS_GetPosition(g_symbol, InpMagic, posTicket, posType);

   if(hasPos)
   {
      ManageOpenPosition(posTicket, posType);

      // While in trade: keep only counter pending (Irsad flip engine)
      if(InpUseCounterPending && InpAllowFlip)
      {
         if(posType == POSITION_TYPE_SELL)
         {
            IRS_CancelType(g_trade, g_symbol, InpMagic, ORDER_TYPE_SELL_STOP);
            if(InpAllowBuy) EnsureBuyStop_TrailDown();
         }
         else if(posType == POSITION_TYPE_BUY)
         {
            IRS_CancelType(g_trade, g_symbol, InpMagic, ORDER_TYPE_BUY_STOP);
            if(InpAllowSell) EnsureSellStop_TrailUp();
         }
      }
      else
      {
         IRS_CancelAllPending(g_trade, g_symbol, InpMagic);
      }
      return;
   }

   ManageEntries();
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   EnforceFlipOrSingle();
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
   if(InpMaxDailyLossPct <= 0.0 || g_dayStartEq <= 0.0) return;

   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   const double dd = ((g_dayStartEq - eq) / g_dayStartEq) * 100.0;
   if(dd >= InpMaxDailyLossPct)
   {
      if(!g_dailyLock)
      {
         PrintFormat("IRS daily lock %.2f%%", dd);
         IRS_CancelAllPending(g_trade, g_symbol, InpMagic);
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
         IRS_CancelAllPending(g_trade, g_symbol, InpMagic);
         PrintFormat("IRS new candle %s open=%.5f — pending reset",
                     TimeToString(t, TIME_DATE|TIME_MINUTES), o);
      }
      g_candleTime = t;
      g_candleOpen = o;
   }
   else g_candleOpen = o;

   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   if(bid < g_candleOpen)      g_bias = -1;
   else if(ask > g_candleOpen) g_bias = +1;
   else                        g_bias = 0;
}

bool BufferSell()
{
   return ((g_candleOpen - SymbolInfoDouble(g_symbol, SYMBOL_BID)) >= InpBufferDistance);
}

bool BufferBuy()
{
   return ((SymbolInfoDouble(g_symbol, SYMBOL_ASK) - g_candleOpen) >= InpBufferDistance);
}

double CalcLot(const ENUM_ORDER_TYPE t, const double px)
{
   return IRS_CalcLot(g_symbol, t, px);
}

//======================================================================
// FLIP ENGINE (Irsad)
//======================================================================
void EnforceFlipOrSingle()
{
   ulong buyTicket = 0, sellTicket = 0;
   datetime buyTime = 0, sellTime = 0;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      const long typ = PositionGetInteger(POSITION_TYPE);
      const datetime tm = (datetime)PositionGetInteger(POSITION_TIME);
      if(typ == POSITION_TYPE_BUY)
      {
         if(buyTicket == 0 || tm >= buyTime) { buyTicket = t; buyTime = tm; }
      }
      else if(typ == POSITION_TYPE_SELL)
      {
         if(sellTicket == 0 || tm >= sellTime) { sellTicket = t; sellTime = tm; }
      }
   }

   if(buyTicket == 0 || sellTicket == 0)
      return;

   if(InpAllowFlip)
   {
      // Newest wins (counter fill flip)
      if(buyTime >= sellTime)
      {
         g_trade.PositionClose(sellTicket);
         IRS_CancelType(g_trade, g_symbol, InpMagic, ORDER_TYPE_BUY_STOP);
         Print("IRS FLIP: SELL closed, BUY kept");
      }
      else
      {
         g_trade.PositionClose(buyTicket);
         IRS_CancelType(g_trade, g_symbol, InpMagic, ORDER_TYPE_SELL_STOP);
         Print("IRS FLIP: BUY closed, SELL kept");
      }
   }
   else
   {
      // Keep older
      if(buyTime <= sellTime)
      {
         g_trade.PositionClose(sellTicket);
         Print("IRS NO-FLIP: closed newer SELL");
      }
      else
      {
         g_trade.PositionClose(buyTicket);
         Print("IRS NO-FLIP: closed newer BUY");
      }
   }
}

//======================================================================
// ENTRY ENGINE
//======================================================================
void ManageEntries()
{
   // SELL priority (below open + buffer)
   if(g_bias < 0 && InpAllowSell && BufferSell())
   {
      EnsureSellStop_TrailUp();
      if(InpUseCounterPending && InpAllowBuy)
         EnsureBuyStop_TrailDown();
      else
         IRS_CancelType(g_trade, g_symbol, InpMagic, ORDER_TYPE_BUY_STOP);
      return;
   }

   // BUY priority (above open + buffer)
   if(g_bias > 0 && InpAllowBuy && BufferBuy())
   {
      EnsureBuyStop_TrailDown();
      if(InpUseCounterPending && InpAllowSell)
         EnsureSellStop_TrailUp();
      else
         IRS_CancelType(g_trade, g_symbol, InpMagic, ORDER_TYPE_SELL_STOP);
      return;
   }

   // Not armed: still ratchet existing pendings
   ulong ticket; double px;
   if(IRS_FindPending(g_symbol, InpMagic, ORDER_TYPE_BUY_STOP, ticket, px))
      EnsureBuyStop_TrailDown();
   if(IRS_FindPending(g_symbol, InpMagic, ORDER_TYPE_SELL_STOP, ticket, px))
      EnsureSellStop_TrailUp();
}

// BUY STOP above Ask | trail DOWN only
void EnsureBuyStop_TrailDown()
{
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double minDist = MathMax(InpPendingOffset, IRS_StopsDist(g_symbol));
   const double desired = IRS_NormPrice(g_symbol, ask + minDist);

   ulong ticket = 0;
   double cur = 0.0;
   if(IRS_FindPending(g_symbol, InpMagic, ORDER_TYPE_BUY_STOP, ticket, cur))
   {
      if(cur <= ask)
      {
         g_trade.OrderDelete(ticket);
      }
      else
      {
         if(desired < cur - IRS_Point(g_symbol) * 0.5)
         {
            if(!g_trade.OrderModify(ticket, desired, 0.0, 0.0, ORDER_TIME_GTC, 0))
               Print("IRS BUY_STOP modify fail: ", g_trade.ResultRetcodeDescription());
         }
         return;
      }
   }

   if(!IRS_FindPending(g_symbol, InpMagic, ORDER_TYPE_BUY_STOP, ticket, cur))
   {
      const double lot = CalcLot(ORDER_TYPE_BUY_STOP, desired);
      if(!g_trade.BuyStop(lot, desired, g_symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "IRS BUY_STOP"))
         Print("IRS BUY_STOP place fail: ", g_trade.ResultRetcodeDescription());
   }
}

// SELL STOP below Bid | trail UP only
void EnsureSellStop_TrailUp()
{
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double minDist = MathMax(InpPendingOffset, IRS_StopsDist(g_symbol));
   const double desired = IRS_NormPrice(g_symbol, bid - minDist);

   ulong ticket = 0;
   double cur = 0.0;
   if(IRS_FindPending(g_symbol, InpMagic, ORDER_TYPE_SELL_STOP, ticket, cur))
   {
      if(cur >= bid)
      {
         g_trade.OrderDelete(ticket);
      }
      else
      {
         if(desired > cur + IRS_Point(g_symbol) * 0.5)
         {
            if(!g_trade.OrderModify(ticket, desired, 0.0, 0.0, ORDER_TIME_GTC, 0))
               Print("IRS SELL_STOP modify fail: ", g_trade.ResultRetcodeDescription());
         }
         return;
      }
   }

   if(!IRS_FindPending(g_symbol, InpMagic, ORDER_TYPE_SELL_STOP, ticket, cur))
   {
      const double lot = CalcLot(ORDER_TYPE_SELL_STOP, desired);
      if(!g_trade.SellStop(lot, desired, g_symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "IRS SELL_STOP"))
         Print("IRS SELL_STOP place fail: ", g_trade.ResultRetcodeDescription());
   }
}

//======================================================================
// POSITION: secure + trail
//======================================================================
void ManageOpenPosition(const ulong ticket, const long posType)
{
   if(!PositionSelectByTicket(ticket)) return;

   const double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   const double sl = PositionGetDouble(POSITION_SL);
   const double tp = PositionGetDouble(POSITION_TP);
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double stops = IRS_StopsDist(g_symbol);

   if(sl <= 0.0 && InpEmergencyStopDist > 0.0)
   {
      const double em = (posType == POSITION_TYPE_BUY)
                        ? IRS_NormPrice(g_symbol, openPrice - InpEmergencyStopDist)
                        : IRS_NormPrice(g_symbol, openPrice + InpEmergencyStopDist);
      g_trade.PositionModify(ticket, em, tp);
      return;
   }

   if(posType == POSITION_TYPE_BUY)
   {
      if(bid - openPrice < InpSecureProfit) return;

      double newSL = IRS_NormPrice(g_symbol, bid - InpTrailDistance);
      const double floorSL = IRS_NormPrice(g_symbol, openPrice + (InpSecureProfit - InpTrailDistance));
      if(newSL < floorSL) newSL = floorSL;

      if(newSL > openPrice && (sl <= 0.0 || newSL > sl + IRS_Point(g_symbol) * 0.5))
      {
         if(bid - newSL >= stops)
            g_trade.PositionModify(ticket, newSL, tp);
      }
   }
   else if(posType == POSITION_TYPE_SELL)
   {
      if(openPrice - ask < InpSecureProfit) return;

      double newSL = IRS_NormPrice(g_symbol, ask + InpTrailDistance);
      const double floorSL = IRS_NormPrice(g_symbol, openPrice - (InpSecureProfit - InpTrailDistance));
      if(newSL > floorSL) newSL = floorSL;

      if(newSL < openPrice && (sl <= 0.0 || newSL < sl - IRS_Point(g_symbol) * 0.5))
      {
         if(newSL - ask >= stops)
            g_trade.PositionModify(ticket, newSL, tp);
      }
   }
}

//+------------------------------------------------------------------+
