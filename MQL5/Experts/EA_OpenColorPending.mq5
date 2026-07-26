//+------------------------------------------------------------------+
//| EA_OpenColorPending.mq5                                          |
//| Open-Color Pending Scalper v1.10 (clean build)                   |
//|                                                                  |
//| Strategy:                                                        |
//|  1) Detect CURRENT candle open                                   |
//|  2) Below open = RED  -> SELL pending at latest LOW only         |
//|  3) Above open = GREEN -> BUY pending at latest HIGH only        |
//|  4) Track previous candle HIGH / LOW                             |
//|  5) On fill: trail SL (ex: 4399 -> SL 4399.5)                    |
//|  6) After profit close -> lock until next candle                 |
//|  7) Emergency SL always attached                                 |
//|                                                                  |
//| Kept:                                                            |
//|  - Dynamic lot by equity                                         |
//|  - Dynamic entries by equity (max 15, $30-$50 => 2-3)            |
//|  - No martingale (same lot per candle)                           |
//|  - XAUUSD + US30                                                 |
//+------------------------------------------------------------------+
#property copyright "Mark Moslares"
#property link      "https://github.com/markazetro1123-cpu/mark-moslares"
#property version   "1.10"
#property description "OpenColor v1.10: red=sell@low, green=buy@high, trail, dynamic lot/entries"

#include <Trade/Trade.mqh>

//======================================================================
// INPUTS
//======================================================================
input group "=== Account / Broker ==="
input long     InpMagic          = 260728;   // Magic number
input double   InpRiskPercent    = 2.0;      // Risk % for dynamic lot
input double   InpMinLot         = 0.01;     // Minimum lot
input double   InpMaxLotCap      = 1.00;     // Maximum lot cap
input int      InpSlippagePoints = 40;       // Order deviation (points)
input bool     InpAllowBuy       = true;     // Allow BUY side
input bool     InpAllowSell      = true;     // Allow SELL side

input group "=== Trail / Stops ==="
input double   InpTrailDistance  = 0.0;      // Trail distance (0 = auto)
input double   InpEmergencySL    = 0.0;      // Emergency SL distance (0 = auto)
input double   InpPendingOffset  = 0.0;      // Pending gap from market (0 = auto)

input group "=== Runtime ==="
input bool     InpPrintLogs      = true;     // Print logs

//======================================================================
// CONSTANTS / ENUMS
//======================================================================
#define OCP_MAX_ENTRIES 15

enum ENUM_OCP_COLOR
{
   OCP_COLOR_NONE  = 0,
   OCP_COLOR_GREEN = 1,
   OCP_COLOR_RED   = -1
};

//======================================================================
// GLOBALS
//======================================================================
CTrade   g_trade;
string   g_symbol;
bool     g_ready     = false;
bool     g_is_gold   = false;
bool     g_is_us30   = false;

datetime g_bar_time    = 0;
bool     g_profit_lock = false;
double   g_cycle_lot   = 0.0;
string   g_last_log    = "";

//======================================================================
// UTILS
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
   const double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   return (point > 0.0 ? point : _Point);
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
   const double vmin  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   const double vmax  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   const double vstep = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);

   if(vstep <= 0.0)
      return vmin;

   volume = MathFloor(volume / vstep + 1e-12) * vstep;
   volume = MathMax(vmin, MathMin(vmax, volume));
   volume = MathMax(InpMinLot, MathMin(InpMaxLotCap, volume));

   int digits = 2;
   if(vstep < 0.01)
      digits = 3;
   if(vstep >= 1.0)
      digits = 0;

   return NormalizeDouble(volume, digits);
}

bool OCP_SelectFilling(ENUM_ORDER_TYPE_FILLING &filling)
{
   const int modes = (int)SymbolInfoInteger(g_symbol, SYMBOL_FILLING_MODE);

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
   const int stops  = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const int freeze = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return (double)MathMax(stops, freeze) * OCP_Point();
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
   const string u = OCP_ToUpper(symbol);
   if(StringFind(u, "XAUUSD") >= 0)
      return true;
   if(StringFind(u, "GOLD") >= 0 && StringFind(u, "GOLDF") < 0)
      return true;
   return false;
}

bool OCP_IsUS30Symbol(const string symbol)
{
   const string u = OCP_ToUpper(symbol);
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
      OCP_Log("Unsupported symbol. Use XAUUSD or US30 family. Symbol=" + g_symbol);
      return false;
   }
   return true;
}

double OCP_TrailDistance()
{
   // Example: price 4399 -> SL 4399.5 => distance 0.5 on US30
   if(InpTrailDistance > 0.0)
      return InpTrailDistance;
   if(g_is_us30)
      return MathMax(0.5, 50.0 * OCP_Point());
   return MathMax(0.20, 50.0 * OCP_Point());
}

double OCP_EmergencyDistance()
{
   if(InpEmergencySL > 0.0)
      return InpEmergencySL;
   if(g_is_us30)
      return MathMax(25.0, 800.0 * OCP_Point());
   return MathMax(3.0, 800.0 * OCP_Point());
}

double OCP_PendingGap()
{
   if(InpPendingOffset > 0.0)
      return InpPendingOffset;

   const double brokerMin = OCP_StopsDistance() + 2.0 * OCP_Point();
   const double softMin   = (g_is_us30 ? 0.5 : 0.05);
   return MathMax(brokerMin, softMin);
}

//======================================================================
// DYNAMIC LOT + ENTRIES
//======================================================================
int OCP_BaseEntriesByEquity(const double equity)
{
   if(equity < 20.0)
      return 1;
   if(equity < 30.0)
      return 2;
   if(equity < 80.0)
      return 3;   // $30-$50 can use up to 3
   if(equity < 150.0)
      return 4;
   if(equity < 300.0)
      return 6;
   if(equity < 600.0)
      return 8;
   if(equity < 1200.0)
      return 11;
   if(equity < 2500.0)
      return 13;
   return OCP_MAX_ENTRIES;
}

int OCP_AllowedEntries()
{
   const int n = OCP_BaseEntriesByEquity(AccountInfoDouble(ACCOUNT_EQUITY));
   if(n < 1)
      return 1;
   if(n > OCP_MAX_ENTRIES)
      return OCP_MAX_ENTRIES;
   return n;
}

double OCP_LossPerLot(const double distance)
{
   if(distance <= 0.0)
      return 0.0;

   const double tickSize  = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
   const double tickValue = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0)
      return 0.0;

   return (distance / tickSize) * tickValue;
}

double OCP_MaxLotByMargin(const ENUM_ORDER_TYPE orderType, const double price)
{
   const double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   const double minLot     = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
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
   // No martingale: reuse lot for whole candle cycle
   if(g_cycle_lot > 0.0)
      return OCP_NormVolume(g_cycle_lot);

   const double equity     = AccountInfoDouble(ACCOUNT_EQUITY);
   const double lossPerLot = OCP_LossPerLot(OCP_EmergencyDistance());

   double lot = InpMinLot;
   if(lossPerLot > 0.0)
      lot = (equity * InpRiskPercent / 100.0) / lossPerLot;

   if(equity >= 100.0)
      lot = MathMax(lot, InpMinLot * 2.0);
   if(equity >= 250.0)
      lot = MathMax(lot, InpMinLot * 3.0);
   if(equity >= 500.0)
      lot = MathMax(lot, InpMinLot * 5.0);
   if(equity >= 1000.0)
      lot = MathMax(lot, InpMinLot * 8.0);
   if(equity >= 2000.0)
      lot = MathMax(lot, InpMinLot * 12.0);

   lot = MathMin(lot, OCP_MaxLotByMargin(orderType, price));
   return OCP_NormVolume(lot);
}

//======================================================================
// CANDLE HELPERS
//======================================================================
bool OCP_CopyBar(const int shift, datetime &barTime, double &open, double &high, double &low)
{
   datetime times[];
   double   opens[];
   double   highs[];
   double   lows[];

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
   open    = opens[0];
   high    = highs[0];
   low     = lows[0];
   return true;
}

ENUM_OCP_COLOR OCP_DetectColor(const double openPrice)
{
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0 || openPrice <= 0.0)
      return OCP_COLOR_NONE;

   const double mid = (bid + ask) * 0.5;
   if(mid < openPrice)
      return OCP_COLOR_RED;
   if(mid > openPrice)
      return OCP_COLOR_GREEN;
   return OCP_COLOR_NONE;
}

//======================================================================
// POSITION / ORDER HELPERS
//======================================================================
int OCP_CountPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
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

int OCP_CountPendingsByType(const ENUM_ORDER_TYPE orderType)
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(!OrderSelect(ticket))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != g_symbol)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != orderType)
         continue;
      count++;
   }
   return count;
}

int OCP_CountAllPendings()
{
   return OCP_CountPendingsByType(ORDER_TYPE_BUY_STOP) +
          OCP_CountPendingsByType(ORDER_TYPE_SELL_STOP) +
          OCP_CountPendingsByType(ORDER_TYPE_BUY_LIMIT) +
          OCP_CountPendingsByType(ORDER_TYPE_SELL_LIMIT);
}

void OCP_DeletePendings(const bool deleteBuys, const bool deleteSells)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(!OrderSelect(ticket))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != g_symbol)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;

      const ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      const bool isBuy  = (type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_LIMIT);
      const bool isSell = (type == ORDER_TYPE_SELL_STOP || type == ORDER_TYPE_SELL_LIMIT);

      if((deleteBuys && isBuy) || (deleteSells && isSell))
         g_trade.OrderDelete(ticket);
   }
}

bool OCP_FindPending(const ENUM_ORDER_TYPE orderType, ulong &ticket, double &price)
{
   ticket = 0;
   price  = 0.0;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      const ulong t = OrderGetTicket(i);
      if(t == 0)
         continue;
      if(!OrderSelect(t))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != g_symbol)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      if((ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) != orderType)
         continue;

      ticket = t;
      price  = OrderGetDouble(ORDER_PRICE_OPEN);
      return true;
   }
   return false;
}

//======================================================================
// ENTRY ENGINE
//======================================================================
bool OCP_PlaceOrMoveSellStop(const double latestLow, const double prevHigh)
{
   if(!InpAllowSell || !OCP_TradeAllowed())
      return false;

   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double gap = OCP_PendingGap();

   double price = OCP_NormPrice(latestLow);
   const double maxValidSell = OCP_NormPrice(bid - MathMax(gap, OCP_StopsDistance() + OCP_Point()));
   if(price > maxValidSell)
      price = maxValidSell;

   const double emergency = MathMax(OCP_EmergencyDistance(), OCP_StopsDistance() + 2.0 * OCP_Point());
   double sl = OCP_NormPrice(price + emergency);
   if(prevHigh > 0.0)
      sl = OCP_NormPrice(MathMax(sl, prevHigh + gap));

   const int allowed = OCP_AllowedEntries();
   const int openCount = OCP_CountPositions();
   const int room = allowed - openCount;
   if(room <= 0)
      return false;

   OCP_PrepareTrade();

   ulong  pendingTicket = 0;
   double pendingPrice  = 0.0;
   if(OCP_FindPending(ORDER_TYPE_SELL_STOP, pendingTicket, pendingPrice))
   {
      // One-way only: move pending down when new low forms
      if(price < pendingPrice - (OCP_Point() * 0.5))
      {
         if(!g_trade.OrderModify(pendingTicket, price, sl, 0.0, ORDER_TIME_GTC, 0))
            OCP_Log("SellStop modify failed retcode=" + IntegerToString((int)g_trade.ResultRetcode()));
         else
            OCP_Log("SELL pending moved to low " + DoubleToString(price, OCP_Digits()));
      }
      return true;
   }

   if(OCP_CountPendingsByType(ORDER_TYPE_SELL_STOP) > 0)
      return true;

   int legs = room;
   if(openCount == 0)
      legs = MathMin(room, MathMin(3, allowed));
   else
      legs = 1;

   const double baseLot = OCP_CalcLot(ORDER_TYPE_SELL, price);
   if(baseLot <= 0.0)
      return false;
   if(g_cycle_lot <= 0.0)
      g_cycle_lot = baseLot;

   const double lot = OCP_NormVolume(baseLot * (double)legs);
   if(!g_trade.SellStop(lot, price, g_symbol, sl, 0.0, ORDER_TIME_GTC, 0, "OCP-SELL"))
   {
      OCP_Log("SellStop place failed retcode=" + IntegerToString((int)g_trade.ResultRetcode()) +
              " " + g_trade.ResultRetcodeDescription());
      return false;
   }

   OCP_Log("SELL pending @ " + DoubleToString(price, OCP_Digits()) +
           " lot=" + DoubleToString(lot, 2) +
           " legs=" + IntegerToString(legs) +
           " prevHigh=" + DoubleToString(prevHigh, OCP_Digits()));
   return true;
}

bool OCP_PlaceOrMoveBuyStop(const double latestHigh, const double prevLow)
{
   if(!InpAllowBuy || !OCP_TradeAllowed())
      return false;

   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double gap = OCP_PendingGap();

   double price = OCP_NormPrice(latestHigh);
   const double minValidBuy = OCP_NormPrice(ask + MathMax(gap, OCP_StopsDistance() + OCP_Point()));
   if(price < minValidBuy)
      price = minValidBuy;

   const double emergency = MathMax(OCP_EmergencyDistance(), OCP_StopsDistance() + 2.0 * OCP_Point());
   double sl = OCP_NormPrice(price - emergency);
   if(prevLow > 0.0)
      sl = OCP_NormPrice(MathMin(sl, prevLow - gap));

   const int allowed = OCP_AllowedEntries();
   const int openCount = OCP_CountPositions();
   const int room = allowed - openCount;
   if(room <= 0)
      return false;

   OCP_PrepareTrade();

   ulong  pendingTicket = 0;
   double pendingPrice  = 0.0;
   if(OCP_FindPending(ORDER_TYPE_BUY_STOP, pendingTicket, pendingPrice))
   {
      // One-way only: move pending up when new high forms
      if(price > pendingPrice + (OCP_Point() * 0.5))
      {
         if(!g_trade.OrderModify(pendingTicket, price, sl, 0.0, ORDER_TIME_GTC, 0))
            OCP_Log("BuyStop modify failed retcode=" + IntegerToString((int)g_trade.ResultRetcode()));
         else
            OCP_Log("BUY pending moved to high " + DoubleToString(price, OCP_Digits()));
      }
      return true;
   }

   if(OCP_CountPendingsByType(ORDER_TYPE_BUY_STOP) > 0)
      return true;

   int legs = room;
   if(openCount == 0)
      legs = MathMin(room, MathMin(3, allowed));
   else
      legs = 1;

   const double baseLot = OCP_CalcLot(ORDER_TYPE_BUY, price);
   if(baseLot <= 0.0)
      return false;
   if(g_cycle_lot <= 0.0)
      g_cycle_lot = baseLot;

   const double lot = OCP_NormVolume(baseLot * (double)legs);
   if(!g_trade.BuyStop(lot, price, g_symbol, sl, 0.0, ORDER_TIME_GTC, 0, "OCP-BUY"))
   {
      OCP_Log("BuyStop place failed retcode=" + IntegerToString((int)g_trade.ResultRetcode()) +
              " " + g_trade.ResultRetcodeDescription());
      return false;
   }

   OCP_Log("BUY pending @ " + DoubleToString(price, OCP_Digits()) +
           " lot=" + DoubleToString(lot, 2) +
           " legs=" + IntegerToString(legs) +
           " prevLow=" + DoubleToString(prevLow, OCP_Digits()));
   return true;
}

//======================================================================
// TRAIL + EMERGENCY SL
//======================================================================
void OCP_ManageOpenPositions()
{
   const double trail = OCP_TrailDistance();
   const double emergency = MathMax(OCP_EmergencyDistance(), OCP_StopsDistance() + 2.0 * OCP_Point());
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double stopLevel = OCP_StopsDistance();

   OCP_PrepareTrade();

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      const long   posType = PositionGetInteger(POSITION_TYPE);
      const double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      const double curSL = PositionGetDouble(POSITION_SL);
      const double curTP = PositionGetDouble(POSITION_TP);

      if(posType == POSITION_TYPE_SELL)
      {
         double workSL = curSL;
         if(workSL <= 0.0)
            workSL = OCP_NormPrice(openPrice + emergency);

         // In profit for sell when bid < open. Example: bid=4399 -> SL=4399.5
         if(bid < openPrice)
         {
            const double newSL = OCP_NormPrice(bid + trail);
            if(newSL < workSL - (OCP_Point() * 0.1))
            {
               if(newSL > bid + stopLevel)
               {
                  if(g_trade.PositionModify(ticket, newSL, curTP))
                     OCP_Log("SELL trail SL -> " + DoubleToString(newSL, OCP_Digits()));
               }
            }
         }
         else if(curSL <= 0.0)
         {
            g_trade.PositionModify(ticket, OCP_NormPrice(openPrice + emergency), curTP);
         }
      }
      else if(posType == POSITION_TYPE_BUY)
      {
         double workSL = curSL;
         if(workSL <= 0.0)
            workSL = OCP_NormPrice(openPrice - emergency);

         if(ask > openPrice)
         {
            const double newSL = OCP_NormPrice(ask - trail);
            if(newSL > workSL + (OCP_Point() * 0.1))
            {
               if(newSL < ask - stopLevel)
               {
                  if(g_trade.PositionModify(ticket, newSL, curTP))
                     OCP_Log("BUY trail SL -> " + DoubleToString(newSL, OCP_Digits()));
               }
            }
         }
         else if(curSL <= 0.0)
         {
            g_trade.PositionModify(ticket, OCP_NormPrice(openPrice - emergency), curTP);
         }
      }
   }
}

//======================================================================
// MAIN FLOW
//======================================================================
void OCP_OnNewBar()
{
   g_profit_lock = false;
   g_cycle_lot   = 0.0;
   OCP_DeletePendings(true, true);
   OCP_Log("New candle -> reset profit-lock and pendings");
}

void OCP_UpdateComment(const ENUM_OCP_COLOR color,
                       const double open0,
                       const double high0,
                       const double low0,
                       const double prevHigh,
                       const double prevLow)
{
   string colorName = "FLAT";
   if(color == OCP_COLOR_RED)
      colorName = "RED / SELL";
   else if(color == OCP_COLOR_GREEN)
      colorName = "GREEN / BUY";

   Comment(
      "OpenColorPending v1.10\n",
      "Symbol: ", g_symbol, (g_is_gold ? " (XAUUSD)" : " (US30)"), "\n",
      "Open: ", DoubleToString(open0, OCP_Digits()), " | Color: ", colorName, "\n",
      "Current H/L: ", DoubleToString(high0, OCP_Digits()), " / ", DoubleToString(low0, OCP_Digits()), "\n",
      "Previous H/L: ", DoubleToString(prevHigh, OCP_Digits()), " / ", DoubleToString(prevLow, OCP_Digits()), "\n",
      "Positions: ", IntegerToString(OCP_CountPositions()),
      " / Allowed: ", IntegerToString(OCP_AllowedEntries()),
      " | Pendings: ", IntegerToString(OCP_CountAllPendings()), "\n",
      "CycleLot: ", (g_cycle_lot > 0.0 ? DoubleToString(g_cycle_lot, 2) : "-"),
      " | Trail: ", DoubleToString(OCP_TrailDistance(), OCP_Digits()), "\n",
      "ProfitLock: ", (g_profit_lock ? "YES (wait next candle)" : "NO")
   );
}

void OCP_OnTickLogic()
{
   datetime time0 = 0;
   datetime time1 = 0;
   double open0 = 0.0, high0 = 0.0, low0 = 0.0;
   double open1 = 0.0, high1 = 0.0, low1 = 0.0;

   if(!OCP_CopyBar(0, time0, open0, high0, low0))
      return;
   if(!OCP_CopyBar(1, time1, open1, high1, low1))
      return;

   // previous candle high/low always available
   const double prevHigh = high1;
   const double prevLow  = low1;
   // open1 kept for clarity/future; silence unused by using in comment path only when needed
   if(open1 <= 0.0 && time1 <= 0)
      return;

   if(time0 != g_bar_time)
   {
      g_bar_time = time0;
      OCP_OnNewBar();
   }

   OCP_ManageOpenPositions();

   const ENUM_OCP_COLOR color = OCP_DetectColor(open0);
   OCP_UpdateComment(color, open0, high0, low0, prevHigh, prevLow);

   if(g_profit_lock)
   {
      OCP_DeletePendings(true, true);
      return;
   }

   if(color == OCP_COLOR_RED)
   {
      // Red candle: SELL only
      OCP_DeletePendings(true, false);
      OCP_PlaceOrMoveSellStop(low0, prevHigh);
   }
   else if(color == OCP_COLOR_GREEN)
   {
      // Green candle: BUY only
      OCP_DeletePendings(false, true);
      OCP_PlaceOrMoveBuyStop(high0, prevLow);
   }
   else
   {
      OCP_DeletePendings(true, true);
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

   const long entry = HistoryDealGetInteger(dealTicket, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      return;

   const double pnl = HistoryDealGetDouble(dealTicket, DEAL_PROFIT) +
                      HistoryDealGetDouble(dealTicket, DEAL_SWAP) +
                      HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);

   if(pnl > 0.0)
   {
      g_profit_lock = true;
      OCP_DeletePendings(true, true);
      OCP_Log("Profit lock ON (pnl=" + DoubleToString(pnl, 2) + "). Wait next candle.");
   }
}

//======================================================================
// EVENTS
//======================================================================
int OnInit()
{
   if(!OCP_ValidateSymbol())
      return INIT_FAILED;

   OCP_PrepareTrade();

   g_bar_time    = 0;
   g_profit_lock = false;
   g_cycle_lot   = 0.0;
   g_last_log    = "";

   OCP_Log("Init OK v1.10 | trail=" + DoubleToString(OCP_TrailDistance(), OCP_Digits()) +
           " | maxEntries=" + IntegerToString(OCP_MAX_ENTRIES) +
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

   // Reference request/result to avoid unused-parameter warnings
   if(request.magic != InpMagic && request.magic != 0 && result.deal != 0 && result.deal != trans.deal)
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
