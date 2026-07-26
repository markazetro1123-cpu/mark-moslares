//+------------------------------------------------------------------+
//| EA_OpenColorPending.mq5                                          |
//| Open-Color Pending Scalper v2.10                                 |
//| Design: DESIGN_OpenColorPending.md                               |
//|                                                                  |
//| GREEN: BUY @ high, trail DOWN only, floor=open                   |
//| RED:   SELL @ low, trail UP only, ceiling=open                   |
//| Delay 5m | Buffer opposite@open | Adjustable RR secure           |
//| Session time filter | Dynamic lot/entries | Emergency SL         |
//+------------------------------------------------------------------+
#property copyright "Mark Moslares"
#property link      "https://github.com/markazetro1123-cpu/mark-moslares"
#property version   "2.10"
#property description "OpenColor v2.10: RR inputs, session filter, delay, one-way pending trail"

#include <Trade/Trade.mqh>

//======================================================================
// INPUTS
//======================================================================
input group "=== Account / Broker ==="
input long   InpMagic                   = 260728; // Magic number
input double InpRiskPercent             = 2.0;    // Risk % for dynamic lot
input double InpMinLot                  = 0.01;   // Minimum lot
input double InpMaxLotCap               = 1.00;   // Maximum lot cap
input int    InpSlippagePoints          = 40;     // Deviation points
input bool   InpAllowBuy                = true;   // Allow BUY
input bool   InpAllowSell               = true;   // Allow SELL

input group "=== Session Clock (PH default) ==="
input bool   InpUseSessionFilter        = true;   // Enable session time filter
input int    InpSessionTZOffsetHrs      = 8;      // Local TZ vs GMT (PH=8)
input int    InpSessionStartHour        = 20;     // Session start hour
input int    InpSessionStartMinute      = 0;      // Session start minute
input int    InpSessionEndHour          = 5;      // Session end hour
input int    InpSessionEndMinute        = 0;      // Session end minute

input group "=== Structure / Buffer ==="
input int    InpStructureDelayMinutes   = 5;      // Anti-fakeout delay (minutes)
input double InpOpenBuffer              = 3.0;    // Buffer distance (price; US30=3.0)

input group "=== Risk Reward / Secure ==="
input double InpSecureTrigger           = 1.0;    // Activate secure when profit >= this
input double InpSecureLock              = 1.0;    // Locked profit once triggered (was 0.5)
input double InpTrailStep               = 0.0;    // Trail step after lock (0=use SecureLock)

input group "=== Stops / Pending ==="
input double InpEmergencySL             = 0.0;    // Emergency SL (0=auto)
input double InpPendingOffset           = 0.0;    // Pending gap (0=auto)

input group "=== Runtime ==="
input bool   InpPrintLogs               = true;   // Print logs

//======================================================================
// CONSTANTS
//======================================================================
const int OCP_MAX_ENTRIES = 15;
const int OCP_FLAT        = 0;
const int OCP_GREEN       = 1;
const int OCP_RED         = 2;

const string OCP_TAG_BUY_MAIN  = "OCP-BM";
const string OCP_TAG_SELL_MAIN = "OCP-SM";
const string OCP_TAG_BUY_OPEN  = "OCP-BO";
const string OCP_TAG_SELL_OPEN = "OCP-SO";

//======================================================================
// GLOBALS
//======================================================================
CTrade   g_trade;
string   g_symbol;
bool     g_ready;
bool     g_is_gold;
bool     g_is_us30;
datetime g_bar_time;
datetime g_delay_until;
double   g_cycle_lot;
string   g_last_log;

//======================================================================
// BASIC HELPERS
//======================================================================
void OCP_Log(const string message)
{
   if(!InpPrintLogs)
      return;
   if(message == g_last_log)
      return;
   g_last_log = message;
   Print("[OpenColor] ", message);
}

double OCP_Point()
{
   double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   if(point <= 0.0)
      point = _Point;
   return point;
}

int OCP_Digits()
{
   return (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
}

double OCP_NormPrice(const double price)
{
   return NormalizeDouble(price, OCP_Digits());
}

double OCP_NormVolume(double volume)
{
   double vmin  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double vmax  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   double vstep = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);

   if(vstep <= 0.0)
      return vmin;

   volume = MathFloor(volume / vstep + 1e-12) * vstep;
   if(volume < vmin) volume = vmin;
   if(volume > vmax) volume = vmax;
   if(volume < InpMinLot) volume = InpMinLot;
   if(volume > InpMaxLotCap) volume = InpMaxLotCap;

   int digits = 2;
   if(vstep < 0.01)
      digits = 3;
   if(vstep >= 1.0)
      digits = 0;

   return NormalizeDouble(volume, digits);
}

bool OCP_SelectFilling(ENUM_ORDER_TYPE_FILLING &filling)
{
   int modes = (int)SymbolInfoInteger(g_symbol, SYMBOL_FILLING_MODE);
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

void OCP_PrepareTrade()
{
   ENUM_ORDER_TYPE_FILLING filling;
   OCP_SelectFilling(filling);
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFilling(filling);
}

double OCP_StopsDistance()
{
   int stops  = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freeze = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   int level  = stops;
   if(freeze > level)
      level = freeze;
   return (double)level * OCP_Point();
}

bool OCP_TradeAllowed()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;
   if(SymbolInfoInteger(g_symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
      return false;
   return true;
}

string OCP_ToUpper(string text)
{
   StringToUpper(text);
   return text;
}

bool OCP_IsGoldSymbol(const string symbol)
{
   string u = OCP_ToUpper(symbol);
   if(StringFind(u, "XAUUSD") >= 0)
      return true;
   if(StringFind(u, "GOLD") >= 0 && StringFind(u, "GOLDF") < 0)
      return true;
   return false;
}

bool OCP_IsUS30Symbol(const string symbol)
{
   string u = OCP_ToUpper(symbol);
   if(StringFind(u, "US30") >= 0)
      return true;
   if(StringFind(u, "DJ30") >= 0)
      return true;
   if(StringFind(u, "DJIA") >= 0)
      return true;
   if(StringFind(u, "WALLSTREET30") >= 0)
      return true;
   if(StringFind(u, "WST30") >= 0)
      return true;
   if(StringFind(u, "DOWJONES") >= 0)
      return true;
   return false;
}

bool OCP_ValidateSymbol()
{
   g_symbol  = _Symbol;
   g_is_gold = OCP_IsGoldSymbol(g_symbol);
   g_is_us30 = OCP_IsUS30Symbol(g_symbol);
   g_ready   = (g_is_gold || g_is_us30);
   if(!g_ready)
   {
      OCP_Log("Unsupported symbol. Use XAUUSD or US30. Symbol=" + g_symbol);
      return false;
   }
   return true;
}

double OCP_SecureTrigger()
{
   if(InpSecureTrigger > 0.0)
      return InpSecureTrigger;
   if(g_is_us30)
      return 1.0;
   return 0.20;
}

double OCP_SecureLock()
{
   if(InpSecureLock > 0.0)
      return InpSecureLock;
   if(g_is_us30)
      return 1.0;
   return 0.20;
}

double OCP_TrailStep()
{
   if(InpTrailStep > 0.0)
      return InpTrailStep;
   return OCP_SecureLock();
}

double OCP_EmergencyDistance()
{
   if(InpEmergencySL > 0.0)
      return InpEmergencySL;
   if(g_is_us30)
      return MathMax(25.0, 800.0 * OCP_Point());
   return MathMax(3.0, 800.0 * OCP_Point());
}

int OCP_LocalMinuteOfDay()
{
   datetime local = TimeGMT() + (datetime)(InpSessionTZOffsetHrs * 3600);
   MqlDateTime dt;
   TimeToStruct(local, dt);
   return dt.hour * 60 + dt.min;
}

bool OCP_InMinuteWindow(const int nowMin, const int startMin, const int endMin)
{
   if(startMin == endMin)
      return true; // same start/end = always open
   if(startMin < endMin)
      return (nowMin >= startMin && nowMin < endMin);
   return (nowMin >= startMin || nowMin < endMin);
}

bool OCP_SessionOK()
{
   if(!InpUseSessionFilter)
      return true;
   int nowMin = OCP_LocalMinuteOfDay();
   int a = InpSessionStartHour * 60 + InpSessionStartMinute;
   int b = InpSessionEndHour * 60 + InpSessionEndMinute;
   return OCP_InMinuteWindow(nowMin, a, b);
}

double OCP_PendingGap()
{
   if(InpPendingOffset > 0.0)
      return InpPendingOffset;

   double brokerMin = OCP_StopsDistance() + 2.0 * OCP_Point();
   double softMin = 0.05;
   if(g_is_us30)
      softMin = 0.5;
   if(brokerMin > softMin)
      return brokerMin;
   return softMin;
}

double OCP_BufferDistance()
{
   if(InpOpenBuffer > 0.0)
      return InpOpenBuffer;
   if(g_is_us30)
      return 3.0;
   return 0.30;
}

//======================================================================
// DYNAMIC LOT / ENTRIES
//======================================================================
int OCP_BaseEntriesByEquity(const double equity)
{
   if(equity < 20.0) return 1;
   if(equity < 30.0) return 2;
   if(equity < 80.0) return 3;
   if(equity < 150.0) return 4;
   if(equity < 300.0) return 6;
   if(equity < 600.0) return 8;
   if(equity < 1200.0) return 11;
   if(equity < 2500.0) return 13;
   return OCP_MAX_ENTRIES;
}

int OCP_AllowedEntries()
{
   int n = OCP_BaseEntriesByEquity(AccountInfoDouble(ACCOUNT_EQUITY));
   if(n < 1) n = 1;
   if(n > OCP_MAX_ENTRIES) n = OCP_MAX_ENTRIES;
   return n;
}

double OCP_LossPerLot(const double distance)
{
   if(distance <= 0.0)
      return 0.0;
   double tickSize  = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0)
      return 0.0;
   return (distance / tickSize) * tickValue;
}

double OCP_MaxLotByMargin(const ENUM_ORDER_TYPE orderType, const double price)
{
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   double minLot     = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   if(freeMargin <= 0.0)
      return minLot;

   double marginOneLot = 0.0;
   if(!OrderCalcMargin(orderType, g_symbol, 1.0, price, marginOneLot) || marginOneLot <= 0.0)
   {
      double marginMin = 0.0;
      if(!OrderCalcMargin(orderType, g_symbol, minLot, price, marginMin) || marginMin <= 0.0)
         return minLot;
      marginOneLot = marginMin / minLot;
   }
   return OCP_NormVolume((freeMargin * 0.65) / marginOneLot);
}

double OCP_CalcLot(const ENUM_ORDER_TYPE orderType, const double price)
{
   if(g_cycle_lot > 0.0)
      return OCP_NormVolume(g_cycle_lot);

   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lossPerLot = OCP_LossPerLot(OCP_EmergencyDistance());
   double lot = InpMinLot;

   if(lossPerLot > 0.0)
      lot = (equity * InpRiskPercent / 100.0) / lossPerLot;

   if(equity >= 100.0)  lot = MathMax(lot, InpMinLot * 2.0);
   if(equity >= 250.0)  lot = MathMax(lot, InpMinLot * 3.0);
   if(equity >= 500.0)  lot = MathMax(lot, InpMinLot * 5.0);
   if(equity >= 1000.0) lot = MathMax(lot, InpMinLot * 8.0);
   if(equity >= 2000.0) lot = MathMax(lot, InpMinLot * 12.0);

   lot = MathMin(lot, OCP_MaxLotByMargin(orderType, price));
   return OCP_NormVolume(lot);
}

//======================================================================
// CANDLE
//======================================================================
bool OCP_CopyBar(const int shift, datetime &barTime, double &openPrice, double &highPrice, double &lowPrice)
{
   datetime times[];
   double opens[];
   double highs[];
   double lows[];

   ArraySetAsSeries(times, true);
   ArraySetAsSeries(opens, true);
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);

   if(CopyTime(g_symbol, PERIOD_CURRENT, shift, 1, times) < 1)
      return false;
   if(CopyOpen(g_symbol, PERIOD_CURRENT, shift, 1, opens) < 1)
      return false;
   if(CopyHigh(g_symbol, PERIOD_CURRENT, shift, 1, highs) < 1)
      return false;
   if(CopyLow(g_symbol, PERIOD_CURRENT, shift, 1, lows) < 1)
      return false;

   barTime = times[0];
   openPrice = opens[0];
   highPrice = highs[0];
   lowPrice = lows[0];
   return true;
}

int OCP_DetectCandleColor(const double openPrice)
{
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0 || openPrice <= 0.0)
      return OCP_FLAT;

   double mid = (bid + ask) * 0.5;
   if(mid < openPrice)
      return OCP_RED;
   if(mid > openPrice)
      return OCP_GREEN;
   return OCP_FLAT;
}

bool OCP_BufferOk(const double openPrice)
{
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double mid = (bid + ask) * 0.5;
   return (MathAbs(mid - openPrice) >= OCP_BufferDistance());
}

//======================================================================
// COUNTS / ORDER HELPERS
//======================================================================
int OCP_CountPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      count++;
   }
   return count;
}

bool OCP_OrderIsOurs(const ulong ticket)
{
   if(!OrderSelect(ticket))
      return false;
   if(OrderGetString(ORDER_SYMBOL) != g_symbol)
      return false;
   if((long)OrderGetInteger(ORDER_MAGIC) != InpMagic)
      return false;
   return true;
}

bool OCP_FindByTag(const string tag, ulong &ticket, double &price)
{
   ticket = 0;
   price = 0.0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong t = OrderGetTicket(i);
      if(t == 0)
         continue;
      if(!OCP_OrderIsOurs(t))
         continue;
      if(OrderGetString(ORDER_COMMENT) != tag)
         continue;

      ticket = t;
      price = OrderGetDouble(ORDER_PRICE_OPEN);
      return true;
   }
   return false;
}

void OCP_DeleteByTag(const string tag)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(!OCP_OrderIsOurs(ticket))
         continue;
      if(OrderGetString(ORDER_COMMENT) != tag)
         continue;
      g_trade.OrderDelete(ticket);
   }
}

void OCP_DeleteAllPendings()
{
   OCP_DeleteByTag(OCP_TAG_BUY_MAIN);
   OCP_DeleteByTag(OCP_TAG_SELL_MAIN);
   OCP_DeleteByTag(OCP_TAG_BUY_OPEN);
   OCP_DeleteByTag(OCP_TAG_SELL_OPEN);
}

int OCP_CountAllPendings()
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(!OCP_OrderIsOurs(ticket))
         continue;
      count++;
   }
   return count;
}

bool OCP_ModifyPending(const ulong ticket, const double price, const double sl)
{
   return g_trade.OrderModify(ticket, price, sl, 0.0, ORDER_TIME_GTC, 0);
}

bool OCP_RoomForNewLegs()
{
   int allowed = OCP_AllowedEntries();
   int openCount = OCP_CountPositions();
   int pendCount = OCP_CountAllPendings();
   return ((openCount + pendCount) < allowed);
}

//======================================================================
// MAIN BUY (GREEN): place @ high, trail DOWN only, floor=open
//======================================================================
bool OCP_ManageBuyMain(const double candleOpen, const double latestHigh)
{
   if(!InpAllowBuy || !OCP_TradeAllowed())
      return false;

   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double gap = OCP_PendingGap();
   double minBuy = OCP_NormPrice(ask + MathMax(gap, OCP_StopsDistance() + OCP_Point()));
   double floorPrice = OCP_NormPrice(candleOpen);

   // desired initial / trail target: never below open, valid buy-stop above ask
   double desired = OCP_NormPrice(latestHigh);
   if(desired < minBuy)
      desired = minBuy;
   if(desired < floorPrice)
      desired = floorPrice;

   // if open is at/above market, buy-stop @ open may be invalid; keep above ask
   if(desired < minBuy)
      desired = minBuy;

   double emergency = MathMax(OCP_EmergencyDistance(), OCP_StopsDistance() + 2.0 * OCP_Point());
   double sl = OCP_NormPrice(desired - emergency);
   if(sl >= desired)
      sl = OCP_NormPrice(desired - MathMax(gap, 2.0 * OCP_Point()));

   OCP_PrepareTrade();

   ulong ticket = 0;
   double curPrice = 0.0;
   bool exists = OCP_FindByTag(OCP_TAG_BUY_MAIN, ticket, curPrice);

   if(exists)
   {
      // Trail DOWN only. Never raise. Never below open floor (except broker minBuy clamp).
      double newPrice = curPrice;
      double trailTarget = OCP_NormPrice(MathMax(floorPrice, minBuy));

      // As price falls, lower pending toward max(open, ask+gap)
      if(trailTarget < curPrice - (OCP_Point() * 0.1))
         newPrice = trailTarget;

      // Never raise above current pending if latestHigh is higher
      double cappedHigh = OCP_NormPrice(MathMax(floorPrice, MathMin(latestHigh, curPrice)));
      if(cappedHigh >= minBuy && cappedHigh < newPrice - (OCP_Point() * 0.1))
         newPrice = cappedHigh;

      if(newPrice < floorPrice)
         newPrice = floorPrice;
      if(newPrice < minBuy)
         newPrice = minBuy;

      newPrice = OCP_NormPrice(newPrice);
      if(newPrice < curPrice - (OCP_Point() * 0.1))
      {
         sl = OCP_NormPrice(newPrice - emergency);
         if(!OCP_ModifyPending(ticket, newPrice, sl))
            OCP_Log("BUY-MAIN modify failed retcode=" + IntegerToString((int)g_trade.ResultRetcode()));
         else
            OCP_Log("BUY-MAIN trail down -> " + DoubleToString(newPrice, OCP_Digits()));
      }
      return true;
   }

   if(!OCP_RoomForNewLegs())
      return false;

   // Initial place at latest high (clamped valid)
   double price = desired;
   if(price < floorPrice)
      price = floorPrice;
   if(price < minBuy)
      price = minBuy;
   price = OCP_NormPrice(price);
   sl = OCP_NormPrice(price - emergency);

   double baseLot = OCP_CalcLot(ORDER_TYPE_BUY, price);
   if(baseLot <= 0.0)
      return false;
   if(g_cycle_lot <= 0.0)
      g_cycle_lot = baseLot;

   int room = OCP_AllowedEntries() - OCP_CountPositions() - OCP_CountAllPendings();
   int legs = 1;
   if(OCP_CountPositions() == 0 && OCP_CountAllPendings() == 0)
   {
      legs = room;
      if(legs > 3) legs = 3;
      if(legs < 1) legs = 1;
   }
   double lot = OCP_NormVolume(baseLot * (double)legs);

   if(!g_trade.BuyStop(lot, price, g_symbol, sl, 0.0, ORDER_TIME_GTC, 0, OCP_TAG_BUY_MAIN))
   {
      OCP_Log("BUY-MAIN place failed retcode=" + IntegerToString((int)g_trade.ResultRetcode()) +
              " " + g_trade.ResultRetcodeDescription());
      return false;
   }

   OCP_Log("BUY-MAIN placed @ " + DoubleToString(price, OCP_Digits()) +
           " lot=" + DoubleToString(lot, 2) +
           " floorOpen=" + DoubleToString(floorPrice, OCP_Digits()));
   return true;
}

//======================================================================
// MAIN SELL (RED): place @ low, trail UP only, ceiling=open
//======================================================================
bool OCP_ManageSellMain(const double candleOpen, const double latestLow)
{
   if(!InpAllowSell || !OCP_TradeAllowed())
      return false;

   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double gap = OCP_PendingGap();
   double maxSell = OCP_NormPrice(bid - MathMax(gap, OCP_StopsDistance() + OCP_Point()));
   double ceiling = OCP_NormPrice(candleOpen);

   double desired = OCP_NormPrice(latestLow);
   if(desired > maxSell)
      desired = maxSell;
   if(desired > ceiling)
      desired = ceiling;

   if(desired > maxSell)
      desired = maxSell;

   double emergency = MathMax(OCP_EmergencyDistance(), OCP_StopsDistance() + 2.0 * OCP_Point());
   double sl = OCP_NormPrice(desired + emergency);

   OCP_PrepareTrade();

   ulong ticket = 0;
   double curPrice = 0.0;
   bool exists = OCP_FindByTag(OCP_TAG_SELL_MAIN, ticket, curPrice);

   if(exists)
   {
      double newPrice = curPrice;
      double trailTarget = OCP_NormPrice(MathMin(ceiling, maxSell));

      // As price rises, raise pending toward min(open, bid-gap)
      if(trailTarget > curPrice + (OCP_Point() * 0.1))
         newPrice = trailTarget;

      double cappedLow = OCP_NormPrice(MathMin(ceiling, MathMax(latestLow, curPrice)));
      if(cappedLow <= maxSell && cappedLow > newPrice + (OCP_Point() * 0.1))
         newPrice = cappedLow;

      if(newPrice > ceiling)
         newPrice = ceiling;
      if(newPrice > maxSell)
         newPrice = maxSell;

      newPrice = OCP_NormPrice(newPrice);
      if(newPrice > curPrice + (OCP_Point() * 0.1))
      {
         sl = OCP_NormPrice(newPrice + emergency);
         if(!OCP_ModifyPending(ticket, newPrice, sl))
            OCP_Log("SELL-MAIN modify failed retcode=" + IntegerToString((int)g_trade.ResultRetcode()));
         else
            OCP_Log("SELL-MAIN trail up -> " + DoubleToString(newPrice, OCP_Digits()));
      }
      return true;
   }

   if(!OCP_RoomForNewLegs())
      return false;

   double price = desired;
   if(price > ceiling)
      price = ceiling;
   if(price > maxSell)
      price = maxSell;
   price = OCP_NormPrice(price);
   sl = OCP_NormPrice(price + emergency);

   double baseLot = OCP_CalcLot(ORDER_TYPE_SELL, price);
   if(baseLot <= 0.0)
      return false;
   if(g_cycle_lot <= 0.0)
      g_cycle_lot = baseLot;

   int room = OCP_AllowedEntries() - OCP_CountPositions() - OCP_CountAllPendings();
   int legs = 1;
   if(OCP_CountPositions() == 0 && OCP_CountAllPendings() == 0)
   {
      legs = room;
      if(legs > 3) legs = 3;
      if(legs < 1) legs = 1;
   }
   double lot = OCP_NormVolume(baseLot * (double)legs);

   if(!g_trade.SellStop(lot, price, g_symbol, sl, 0.0, ORDER_TIME_GTC, 0, OCP_TAG_SELL_MAIN))
   {
      OCP_Log("SELL-MAIN place failed retcode=" + IntegerToString((int)g_trade.ResultRetcode()) +
              " " + g_trade.ResultRetcodeDescription());
      return false;
   }

   OCP_Log("SELL-MAIN placed @ " + DoubleToString(price, OCP_Digits()) +
           " lot=" + DoubleToString(lot, 2) +
           " ceilingOpen=" + DoubleToString(ceiling, OCP_Digits()));
   return true;
}

//======================================================================
// OPPOSITE @ OPEN (buffer rule)
// GREEN + buffer: SELL LIMIT @ open
// RED   + buffer: BUY  LIMIT @ open
//======================================================================
bool OCP_ManageSellAtOpen(const double candleOpen)
{
   if(!InpAllowSell || !OCP_TradeAllowed())
      return false;

   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double gap = OCP_PendingGap();
   double price = OCP_NormPrice(candleOpen);

   // Sell Limit must be above bid
   double minSellLimit = OCP_NormPrice(bid + MathMax(gap, OCP_StopsDistance() + OCP_Point()));
   if(price < minSellLimit)
   {
      // open not usable as sell-limit right now
      OCP_DeleteByTag(OCP_TAG_SELL_OPEN);
      return false;
   }

   double emergency = MathMax(OCP_EmergencyDistance(), OCP_StopsDistance() + 2.0 * OCP_Point());
   double sl = OCP_NormPrice(price + emergency);

   OCP_PrepareTrade();

   ulong ticket = 0;
   double curPrice = 0.0;
   if(OCP_FindByTag(OCP_TAG_SELL_OPEN, ticket, curPrice))
   {
      if(MathAbs(curPrice - price) > OCP_Point() * 0.1)
      {
         if(!OCP_ModifyPending(ticket, price, sl))
            OCP_Log("SELL-OPEN modify failed retcode=" + IntegerToString((int)g_trade.ResultRetcode()));
      }
      return true;
   }

   if(!OCP_RoomForNewLegs())
      return false;

   double lot = OCP_CalcLot(ORDER_TYPE_SELL, price);
   if(lot <= 0.0)
      return false;
   if(g_cycle_lot <= 0.0)
      g_cycle_lot = lot;

   if(!g_trade.SellLimit(lot, price, g_symbol, sl, 0.0, ORDER_TIME_GTC, 0, OCP_TAG_SELL_OPEN))
   {
      OCP_Log("SELL-OPEN place failed retcode=" + IntegerToString((int)g_trade.ResultRetcode()) +
              " " + g_trade.ResultRetcodeDescription());
      return false;
   }

   OCP_Log("SELL-OPEN placed @ open " + DoubleToString(price, OCP_Digits()));
   return true;
}

bool OCP_ManageBuyAtOpen(const double candleOpen)
{
   if(!InpAllowBuy || !OCP_TradeAllowed())
      return false;

   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double gap = OCP_PendingGap();
   double price = OCP_NormPrice(candleOpen);

   // Buy Limit must be below ask
   double maxBuyLimit = OCP_NormPrice(ask - MathMax(gap, OCP_StopsDistance() + OCP_Point()));
   if(price > maxBuyLimit)
   {
      OCP_DeleteByTag(OCP_TAG_BUY_OPEN);
      return false;
   }

   double emergency = MathMax(OCP_EmergencyDistance(), OCP_StopsDistance() + 2.0 * OCP_Point());
   double sl = OCP_NormPrice(price - emergency);

   OCP_PrepareTrade();

   ulong ticket = 0;
   double curPrice = 0.0;
   if(OCP_FindByTag(OCP_TAG_BUY_OPEN, ticket, curPrice))
   {
      if(MathAbs(curPrice - price) > OCP_Point() * 0.1)
      {
         if(!OCP_ModifyPending(ticket, price, sl))
            OCP_Log("BUY-OPEN modify failed retcode=" + IntegerToString((int)g_trade.ResultRetcode()));
      }
      return true;
   }

   if(!OCP_RoomForNewLegs())
      return false;

   double lot = OCP_CalcLot(ORDER_TYPE_BUY, price);
   if(lot <= 0.0)
      return false;
   if(g_cycle_lot <= 0.0)
      g_cycle_lot = lot;

   if(!g_trade.BuyLimit(lot, price, g_symbol, sl, 0.0, ORDER_TIME_GTC, 0, OCP_TAG_BUY_OPEN))
   {
      OCP_Log("BUY-OPEN place failed retcode=" + IntegerToString((int)g_trade.ResultRetcode()) +
              " " + g_trade.ResultRetcodeDescription());
      return false;
   }

   OCP_Log("BUY-OPEN placed @ open " + DoubleToString(price, OCP_Digits()));
   return true;
}

//======================================================================
// POSITION EMERGENCY SL + ADJUSTABLE RR SECURE / TRAIL
//======================================================================
void OCP_ManageOpenPositions()
{
   double trigger = OCP_SecureTrigger();
   double lockDist = OCP_SecureLock();
   double trailStep = OCP_TrailStep();
   double emergency = MathMax(OCP_EmergencyDistance(), OCP_StopsDistance() + 2.0 * OCP_Point());
   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double stopLevel = OCP_StopsDistance();
   double eps = OCP_Point() * 0.1;

   OCP_PrepareTrade();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      long posType = PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL = PositionGetDouble(POSITION_SL);
      double curTP = PositionGetDouble(POSITION_TP);

      if(posType == POSITION_TYPE_SELL)
      {
         if(curSL <= 0.0)
         {
            double emSL = OCP_NormPrice(openPrice + emergency);
            g_trade.PositionModify(ticket, emSL, curTP);
            curSL = emSL;
         }

         double profitDist = openPrice - bid;
         if(profitDist < trigger)
            continue;

         // Lock at least SecureLock profit, then trail by TrailStep
         double lockSL = OCP_NormPrice(openPrice - lockDist);
         double trailSL = OCP_NormPrice(bid + trailStep);
         double newSL = lockSL;
         if(trailSL < newSL)
            newSL = trailSL;

         if(newSL >= bid + stopLevel)
            continue;
         if(curSL > 0.0 && newSL >= curSL - eps)
            continue;

         if(g_trade.PositionModify(ticket, newSL, curTP))
            OCP_Log("SELL secure/trail SL -> " + DoubleToString(newSL, OCP_Digits()) +
                    " (trigger=" + DoubleToString(trigger, OCP_Digits()) +
                    " lock=" + DoubleToString(lockDist, OCP_Digits()) + ")");
      }
      else if(posType == POSITION_TYPE_BUY)
      {
         if(curSL <= 0.0)
         {
            double emSL = OCP_NormPrice(openPrice - emergency);
            g_trade.PositionModify(ticket, emSL, curTP);
            curSL = emSL;
         }

         double profitDist = ask - openPrice;
         if(profitDist < trigger)
            continue;

         double lockSL = OCP_NormPrice(openPrice + lockDist);
         double trailSL = OCP_NormPrice(ask - trailStep);
         double newSL = lockSL;
         if(trailSL > newSL)
            newSL = trailSL;

         if(newSL > ask - stopLevel)
            continue;
         if(curSL > 0.0 && newSL <= curSL + eps)
            continue;

         if(g_trade.PositionModify(ticket, newSL, curTP))
            OCP_Log("BUY secure/trail SL -> " + DoubleToString(newSL, OCP_Digits()) +
                    " (trigger=" + DoubleToString(trigger, OCP_Digits()) +
                    " lock=" + DoubleToString(lockDist, OCP_Digits()) + ")");
      }
   }
}

//======================================================================
// UI / FLOW
//======================================================================
void OCP_OnNewBar(const datetime barTime)
{
   g_bar_time = barTime;
   g_cycle_lot = 0.0;

   int delayMin = InpStructureDelayMinutes;
   if(delayMin < 0)
      delayMin = 0;
   g_delay_until = barTime + (datetime)(delayMin * 60);

   OCP_DeleteAllPendings();
   OCP_Log("New candle -> delay until " + TimeToString(g_delay_until, TIME_DATE|TIME_MINUTES));
}

void OCP_UpdateComment(const int candleColor,
                       const double open0,
                       const double high0,
                       const double low0,
                       const double prevHigh,
                       const double prevLow,
                       const bool delayActive,
                       const bool sessionOk)
{
   string colorName = "FLAT";
   if(candleColor == OCP_RED)
      colorName = "RED / SELL-MAIN";
   if(candleColor == OCP_GREEN)
      colorName = "GREEN / BUY-MAIN";

   string family = " (US30)";
   if(g_is_gold)
      family = " (XAUUSD)";

   string lotText = "-";
   if(g_cycle_lot > 0.0)
      lotText = DoubleToString(g_cycle_lot, 2);

   string delayText = "READY";
   if(delayActive)
      delayText = "WAIT " + TimeToString(g_delay_until, TIME_MINUTES|TIME_SECONDS);

   string bufText = "NO";
   if(OCP_BufferOk(open0))
      bufText = "YES";

   string sessionText = "OFF";
   if(InpUseSessionFilter)
   {
      if(sessionOk)
         sessionText = "OK";
      else
         sessionText = "BLOCK";
   }

   string line1 = "OpenColorPending v2.10";
   string line2 = "Symbol: " + g_symbol + family + " | Session: " + sessionText;
   string line3 = "Open: " + DoubleToString(open0, OCP_Digits()) + " | Color: " + colorName;
   string line4 = "Current H/L: " + DoubleToString(high0, OCP_Digits()) + " / " + DoubleToString(low0, OCP_Digits());
   string line5 = "Previous H/L: " + DoubleToString(prevHigh, OCP_Digits()) + " / " + DoubleToString(prevLow, OCP_Digits());
   string line6 = "Delay: " + delayText + " | BufferOK: " + bufText +
                  " (" + DoubleToString(OCP_BufferDistance(), OCP_Digits()) + ")";
   string line7 = "RR trigger/lock/step: " +
                  DoubleToString(OCP_SecureTrigger(), OCP_Digits()) + " / " +
                  DoubleToString(OCP_SecureLock(), OCP_Digits()) + " / " +
                  DoubleToString(OCP_TrailStep(), OCP_Digits());
   string line8 = "Pos: " + IntegerToString(OCP_CountPositions()) +
                  " / Allow: " + IntegerToString(OCP_AllowedEntries()) +
                  " | Pend: " + IntegerToString(OCP_CountAllPendings()) +
                  " | Lot: " + lotText;

   Comment(line1, "\n", line2, "\n", line3, "\n", line4, "\n", line5, "\n", line6, "\n", line7, "\n", line8);
}

void OCP_OnTickLogic()
{
   datetime time0 = 0;
   datetime time1 = 0;
   double open0 = 0.0;
   double high0 = 0.0;
   double low0 = 0.0;
   double open1 = 0.0;
   double high1 = 0.0;
   double low1 = 0.0;

   if(!OCP_CopyBar(0, time0, open0, high0, low0))
      return;
   if(!OCP_CopyBar(1, time1, open1, high1, low1))
      return;

   if(open1 <= 0.0 || time1 <= 0)
      return;

   if(time0 != g_bar_time)
      OCP_OnNewBar(time0);

   OCP_ManageOpenPositions();

   int candleColor = OCP_DetectCandleColor(open0);
   bool delayActive = (TimeCurrent() < g_delay_until);
   bool sessionOk = OCP_SessionOK();
   OCP_UpdateComment(candleColor, open0, high0, low0, high1, low1, delayActive, sessionOk);

   if(!sessionOk)
   {
      // Outside session: no new pendings; keep managing open positions only
      OCP_DeleteAllPendings();
      return;
   }

   if(delayActive)
      return;

   if(candleColor == OCP_GREEN)
   {
      // Main BUY only; cancel sell-main
      OCP_DeleteByTag(OCP_TAG_SELL_MAIN);
      OCP_ManageBuyMain(open0, high0);

      if(OCP_BufferOk(open0))
         OCP_ManageSellAtOpen(open0);
      else
         OCP_DeleteByTag(OCP_TAG_SELL_OPEN);

      // no buy@open on green
      OCP_DeleteByTag(OCP_TAG_BUY_OPEN);
   }
   else if(candleColor == OCP_RED)
   {
      OCP_DeleteByTag(OCP_TAG_BUY_MAIN);
      OCP_ManageSellMain(open0, low0);

      if(OCP_BufferOk(open0))
         OCP_ManageBuyAtOpen(open0);
      else
         OCP_DeleteByTag(OCP_TAG_BUY_OPEN);

      OCP_DeleteByTag(OCP_TAG_SELL_OPEN);
   }
   else
   {
      // FLAT: cancel mains; keep open-side only if buffer still valid
      OCP_DeleteByTag(OCP_TAG_BUY_MAIN);
      OCP_DeleteByTag(OCP_TAG_SELL_MAIN);
      OCP_DeleteByTag(OCP_TAG_BUY_OPEN);
      OCP_DeleteByTag(OCP_TAG_SELL_OPEN);
   }
}

void OCP_HandleClosedDeal(const ulong dealTicket)
{
   if(!HistoryDealSelect(dealTicket))
      return;
   if(HistoryDealGetString(dealTicket, DEAL_SYMBOL) != g_symbol)
      return;
   if((long)HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != InpMagic)
      return;

   long entry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      return;

   double pnl = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
   pnl += HistoryDealGetDouble(dealTicket, DEAL_SWAP);
   pnl += HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);

   if(pnl > 0.0)
   {
      // Profit -> clear pendings and allow fresh cycle under same candle rules
      OCP_DeleteAllPendings();
      g_cycle_lot = 0.0;
      OCP_Log("Profit close pnl=" + DoubleToString(pnl, 2) + " -> re-arm pending cycle");
   }
}

//======================================================================
// EVENTS
//======================================================================
int OnInit()
{
   g_ready = false;
   g_is_gold = false;
   g_is_us30 = false;
   g_bar_time = 0;
   g_delay_until = 0;
   g_cycle_lot = 0.0;
   g_last_log = "";
   g_symbol = "";

   if(!OCP_ValidateSymbol())
      return INIT_FAILED;

   if(InpSessionTZOffsetHrs < -12 || InpSessionTZOffsetHrs > 14)
   {
      OCP_Log("Invalid InpSessionTZOffsetHrs");
      return INIT_FAILED;
   }
   if(InpSessionStartHour < 0 || InpSessionStartHour > 23 ||
      InpSessionEndHour < 0 || InpSessionEndHour > 23 ||
      InpSessionStartMinute < 0 || InpSessionStartMinute > 59 ||
      InpSessionEndMinute < 0 || InpSessionEndMinute > 59)
   {
      OCP_Log("Invalid session clock inputs");
      return INIT_FAILED;
   }

   OCP_PrepareTrade();

   string sessionMode = "OFF";
   if(InpUseSessionFilter)
      sessionMode = "ON";

   OCP_Log("Init OK v2.10 | delay=" + IntegerToString(InpStructureDelayMinutes) +
           "m | buffer=" + DoubleToString(OCP_BufferDistance(), OCP_Digits()) +
           " | RR trigger/lock=" + DoubleToString(OCP_SecureTrigger(), OCP_Digits()) +
           "/" + DoubleToString(OCP_SecureLock(), OCP_Digits()) +
           " | sessionFilter=" + sessionMode +
           " | symbol=" + g_symbol);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");
   OCP_Log("Deinit reason=" + IntegerToString(reason));
}

void OnTick()
{
   if(!g_ready)
      return;
   OCP_OnTickLogic();
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(trans.deal == 0)
      return;

   // touch request/result (avoid unused-parameter warnings)
   long reqMagic = request.magic;
   uint retcode = result.retcode;
   if(reqMagic < -1)
      return;
   if(retcode == 999999)
      return;

   if(!HistoryDealSelect(trans.deal))
   {
      HistorySelect(TimeCurrent() - 86400, TimeCurrent() + 60);
      if(!HistoryDealSelect(trans.deal))
         return;
   }

   OCP_HandleClosedDeal(trans.deal);
}
//+------------------------------------------------------------------+
