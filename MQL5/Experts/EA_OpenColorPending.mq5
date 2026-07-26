//+------------------------------------------------------------------+
//| EA_OpenColorPending.mq5                                          |
//| Open-price color pending + trail (XAUUSD / US30)                 |
//|                                                                  |
//| ENTRY STRATEGY:                                                  |
//|  - Watch CURRENT candle open                                     |
//|  - Below open = RED  -> SELL pending only at latest low          |
//|  - Above open = GREEN -> BUY pending only at latest high         |
//|  - Detect previous candle HIGH / LOW                             |
//|  - On fill: trail SL (ex: price 4399 -> SL 4399.5)               |
//|  - After profit on that side/candle -> cooldown until next candle|
//|  - Emergency SL always attached                                  |
//|                                                                  |
//| KEPT FROM BEFORE:                                                |
//|  - Dynamic lot by equity                                         |
//|  - Dynamic entry count by equity (max 15, $30-$50 => 2-3)        |
//|  - No martingale (same lot per candle cycle)                     |
//+------------------------------------------------------------------+
#property copyright "Mark Moslares"
#property link      "https://github.com/markazetro1123-cpu/mark-moslares"
#property version   "1.00"
#property description "Open-color pending: red=sell@low, green=buy@high, trail SL, dynamic lot/entries"

#include <Trade/Trade.mqh>

//======================================================================
// INPUTS (minimal)
//======================================================================
input group "=== Account / Broker ==="
input long   InpMagic           = 260728;  // Magic number
input double InpRiskPercent     = 2.0;     // Risk % for dynamic lot
input double InpMinLot          = 0.01;    // Min lot
input double InpMaxLotCap       = 1.00;    // Max lot cap
input int    InpSlippagePoints  = 40;      // Deviation
input bool   InpAllowBuy        = true;
input bool   InpAllowSell       = true;

input group "=== Trail / Stops ==="
input double InpTrailDistance   = 0.0;     // Trail distance (0=auto)
input double InpEmergencySL     = 0.0;     // Emergency SL distance (0=auto)
input double InpPendingOffset   = 0.0;     // Extra offset from high/low (0=auto)

input group "=== Runtime ==="
input bool   InpPrintLogs       = true;

//======================================================================
// CONSTANTS (dynamic entries kept)
//======================================================================
const int OCP_MAX_ENTRIES = 15;

enum ENUM_OCP_COLOR
{
   OCP_NONE = 0,
   OCP_GREEN = 1,
   OCP_RED = -1
};

//======================================================================
CTrade trade;
string g_symbol;
bool   g_ok = false;
bool   g_is_gold = false;
bool   g_is_us30 = false;

datetime g_candle_time = 0;
bool     g_profit_lock = false;     // after profit this candle -> stop
double   g_cycle_lot = 0.0;
string   g_last_log = "";

//======================================================================
void OCP_Log(const string msg)
{
   if(!InpPrintLogs) return;
   if(msg == g_last_log) return;
   g_last_log = msg;
   Print("[OpenColor] ", msg);
}

double OCP_Point()
{
   const double p = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   return (p > 0.0 ? p : _Point);
}

int OCP_Digits()
{
   return (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
}

double OCP_NormPrice(const double price)
{
   return NormalizeDouble(price, OCP_Digits());
}

double OCP_NormVol(double vol)
{
   const double vmin  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   const double vmax  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   const double vstep = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   if(vstep <= 0.0) return vmin;
   vol = MathFloor(vol / vstep + 1e-12) * vstep;
   vol = MathMax(vmin, MathMin(vmax, vol));
   vol = MathMax(InpMinLot, MathMin(InpMaxLotCap, vol));
   int d = 2;
   if(vstep < 0.01) d = 3;
   if(vstep >= 1.0) d = 0;
   return NormalizeDouble(vol, d);
}

bool OCP_SelectFilling(ENUM_ORDER_TYPE_FILLING &filling)
{
   const int modes = (int)SymbolInfoInteger(g_symbol, SYMBOL_FILLING_MODE);
   if((modes & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) { filling = ORDER_FILLING_IOC; return true; }
   if((modes & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) { filling = ORDER_FILLING_FOK; return true; }
   filling = ORDER_FILLING_RETURN;
   return true;
}

double OCP_StopsDist()
{
   const int stops  = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const int freeze = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return MathMax(stops, freeze) * OCP_Point();
}

bool OCP_TradeOk()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;
   if(SymbolInfoInteger(g_symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED) return false;
   return true;
}

string OCP_Upper(string s){ StringToUpper(s); return s; }

bool OCP_IsGold(const string s)
{
   const string u = OCP_Upper(s);
   return (StringFind(u, "XAUUSD") >= 0 || (StringFind(u, "GOLD") >= 0 && StringFind(u, "GOLDF") < 0));
}

bool OCP_IsUS30(const string s)
{
   const string u = OCP_Upper(s);
   return (StringFind(u, "US30") >= 0 || StringFind(u, "DJ30") >= 0 || StringFind(u, "DJIA") >= 0 ||
           StringFind(u, "WALLSTREET30") >= 0 || StringFind(u, "WST30") >= 0 || StringFind(u, "DOWJONES") >= 0);
}

bool OCP_ValidateSymbol()
{
   g_symbol = _Symbol;
   g_is_gold = OCP_IsGold(g_symbol);
   g_is_us30 = OCP_IsUS30(g_symbol);
   g_ok = (g_is_gold || g_is_us30);
   if(!g_ok)
   {
      OCP_Log("Unsupported symbol (use XAUUSD / US30 family): " + g_symbol);
      return false;
   }
   return true;
}

double OCP_TrailDist()
{
   // Example behavior: 4399 -> SL 4399.5 => 0.5 on US30
   if(InpTrailDistance > 0.0) return InpTrailDistance;
   if(g_is_us30) return MathMax(0.5, 50.0 * OCP_Point());
   return MathMax(0.20, 50.0 * OCP_Point());
}

double OCP_EmergencyDist()
{
   if(InpEmergencySL > 0.0) return InpEmergencySL;
   if(g_is_us30) return MathMax(25.0, 800.0 * OCP_Point());
   return MathMax(3.0, 800.0 * OCP_Point());
}

double OCP_PendingGap()
{
   if(InpPendingOffset > 0.0) return InpPendingOffset;
   return MathMax(OCP_StopsDist() + 2.0 * OCP_Point(), (g_is_us30 ? 0.5 : 0.05));
}

//======================================================================
// DYNAMIC LOT + ENTRIES (kept)
//======================================================================
int OCP_BaseEntries(const double eq)
{
   if(eq < 20.0) return 1;
   if(eq < 30.0) return 2;
   if(eq < 80.0) return 3;   // $30-$50 zone -> up to 3
   if(eq < 150.0) return 4;
   if(eq < 300.0) return 6;
   if(eq < 600.0) return 8;
   if(eq < 1200.0) return 11;
   if(eq < 2500.0) return 13;
   return OCP_MAX_ENTRIES;
}

int OCP_AllowedEntries()
{
   const int n = OCP_BaseEntries(AccountInfoDouble(ACCOUNT_EQUITY));
   return (int)MathMax(1, MathMin(OCP_MAX_ENTRIES, n));
}

double OCP_LossPerLot(const double dist)
{
   if(dist <= 0.0) return 0.0;
   const double ts = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
   const double tv = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);
   if(ts <= 0.0 || tv <= 0.0) return 0.0;
   return (dist / ts) * tv;
}

double OCP_MaxLotMargin(const ENUM_ORDER_TYPE type, const double price)
{
   const double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   const double vmin = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   if(free <= 0.0) return vmin;
   double m1 = 0.0;
   if(!OrderCalcMargin(type, g_symbol, 1.0, price, m1) || m1 <= 0.0)
   {
      double mm = 0.0;
      if(!OrderCalcMargin(type, g_symbol, vmin, price, mm) || mm <= 0.0) return vmin;
      m1 = mm / vmin;
   }
   return OCP_NormVol((free * 0.65) / m1);
}

double OCP_CalcLot(const ENUM_ORDER_TYPE type, const double price)
{
   if(g_cycle_lot > 0.0)
      return OCP_NormVol(g_cycle_lot);

   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   const double lpl = OCP_LossPerLot(OCP_EmergencyDist());
   double lot = InpMinLot;
   if(lpl > 0.0)
      lot = (eq * InpRiskPercent / 100.0) / lpl;

   if(eq >= 100.0)  lot = MathMax(lot, InpMinLot * 2.0);
   if(eq >= 250.0)  lot = MathMax(lot, InpMinLot * 3.0);
   if(eq >= 500.0)  lot = MathMax(lot, InpMinLot * 5.0);
   if(eq >= 1000.0) lot = MathMax(lot, InpMinLot * 8.0);
   if(eq >= 2000.0) lot = MathMax(lot, InpMinLot * 12.0);

   lot = MathMin(lot, OCP_MaxLotMargin(type, price));
   return OCP_NormVol(lot);
}

//======================================================================
// CANDLE DATA
//======================================================================
bool OCP_GetCandle(const int shift, datetime &t, double &o, double &h, double &l, double &c)
{
   double oo[], hh[], ll[], cc[];
   datetime tt[];
   ArraySetAsSeries(oo, true);
   ArraySetAsSeries(hh, true);
   ArraySetAsSeries(ll, true);
   ArraySetAsSeries(cc, true);
   ArraySetAsSeries(tt, true);
   if(CopyOpen(g_symbol, PERIOD_CURRENT, shift, 1, oo) < 1) return false;
   if(CopyHigh(g_symbol, PERIOD_CURRENT, shift, 1, hh) < 1) return false;
   if(CopyLow(g_symbol, PERIOD_CURRENT, shift, 1, ll) < 1) return false;
   if(CopyClose(g_symbol, PERIOD_CURRENT, shift, 1, cc) < 1) return false;
   if(CopyTime(g_symbol, PERIOD_CURRENT, shift, 1, tt) < 1) return false;
   t = tt[0]; o = oo[0]; h = hh[0]; l = ll[0]; c = cc[0];
   return true;
}

ENUM_OCP_COLOR OCP_ColorFromOpen(const double openPrice)
{
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0 || openPrice <= 0.0) return OCP_NONE;
   const double mid = (bid + ask) * 0.5;
   if(mid < openPrice) return OCP_RED;
   if(mid > openPrice) return OCP_GREEN;
   return OCP_NONE;
}

//======================================================================
// POSITIONS / ORDERS
//======================================================================
int OCP_CountPositions()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      n++;
   }
   return n;
}

int OCP_CountPendings(const long typeFilter = -1)
{
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0) continue;
      if(!OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != g_symbol) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      const long type = OrderGetInteger(ORDER_TYPE);
      if(typeFilter >= 0 && type != typeFilter) continue;
      if(type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP ||
         type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_SELL_LIMIT)
         n++;
   }
   return n;
}

void OCP_DeletePendings(const bool buys, const bool sells)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !OrderSelect(ticket)) continue;
      if(OrderGetString(ORDER_SYMBOL) != g_symbol) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      const long type = OrderGetInteger(ORDER_TYPE);
      const bool isBuy = (type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_LIMIT);
      const bool isSell = (type == ORDER_TYPE_SELL_STOP || type == ORDER_TYPE_SELL_LIMIT);
      if((buys && isBuy) || (sells && isSell))
         trade.OrderDelete(ticket);
   }
}

bool OCP_FindPending(const long type, ulong &ticket, double &price)
{
   ticket = 0;
   price = 0.0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      const ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL) != g_symbol) continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagic) continue;
      if((long)OrderGetInteger(ORDER_TYPE) != type) continue;
      ticket = t;
      price = OrderGetDouble(ORDER_PRICE_OPEN);
      return true;
   }
   return false;
}

double OCP_FloatingProfit()
{
   double pnl = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      pnl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return pnl;
}

bool OCP_CloseAll(const string why)
{
   bool ok = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(!trade.PositionClose(ticket)) ok = false;
   }
   if(ok) OCP_Log("Closed all: " + why);
   return ok;
}

//======================================================================
// ENTRY ENGINE (new strategy)
//======================================================================
bool OCP_PlaceOrMoveSellAtLow(const double latestLow, const double prevHigh)
{
   if(!InpAllowSell || !OCP_TradeOk()) return false;

   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double gap = OCP_PendingGap();
   // SellStop at latest low (below/at market side for continuation down)
   double price = OCP_NormPrice(latestLow);
   // ensure valid stop distance from market
   const double minSell = OCP_NormPrice(bid - MathMax(gap, OCP_StopsDist() + OCP_Point()));
   if(price > minSell)
      price = minSell;

   const double emerg = MathMax(OCP_EmergencyDist(), OCP_StopsDist() + 2.0 * OCP_Point());
   // emergency SL above entry; also respect previous high as structure ceiling helper
   double sl = OCP_NormPrice(price + emerg);
   if(prevHigh > 0.0)
      sl = OCP_NormPrice(MathMax(sl, prevHigh + gap));

   const int allowed = OCP_AllowedEntries();
   const int openN = OCP_CountPositions();
   const int pendN = OCP_CountPendings(ORDER_TYPE_SELL_STOP);
   const int room = allowed - openN;
   if(room <= 0) return false;

   ENUM_ORDER_TYPE_FILLING fill;
   OCP_SelectFilling(fill);
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFilling(fill);

   ulong ticket = 0;
   double oldPrice = 0.0;
   if(OCP_FindPending(ORDER_TYPE_SELL_STOP, ticket, oldPrice))
   {
      // one-way: only move pending DOWN to newer low
      if(price < oldPrice - OCP_Point() * 0.5)
      {
         if(!trade.OrderModify(ticket, price, sl, 0.0, 0))
            OCP_Log("SellStop modify fail " + IntegerToString((int)trade.ResultRetcode()));
         else
            OCP_Log("SELL pending trail low -> " + DoubleToString(price, OCP_Digits()));
      }
      return true;
   }

   if(pendN > 0) return true;

   // Dynamic entries as one pending volume (same price; brokers reject duplicate stops)
   const int legs = MathMin(room, (openN == 0 ? MathMin(3, allowed) : 1));
   const double baseLot = OCP_CalcLot(ORDER_TYPE_SELL, price);
   if(baseLot <= 0.0) return false;
   if(g_cycle_lot <= 0.0) g_cycle_lot = baseLot;
   const double lot = OCP_NormVol(baseLot * legs);

   if(!trade.SellStop(lot, price, g_symbol, sl, 0.0, ORDER_TIME_GTC, 0, "OCP-SELL"))
   {
      OCP_Log("SellStop place fail " + IntegerToString((int)trade.ResultRetcode()) +
              " " + trade.ResultRetcodeDescription());
      return false;
   }
   OCP_Log("SELL pending @ low " + DoubleToString(price, OCP_Digits()) +
           " lot=" + DoubleToString(lot, 2) + " (legs=" + IntegerToString(legs) + ")" +
           " prevHigh=" + DoubleToString(prevHigh, OCP_Digits()));
   return true;
}

bool OCP_PlaceOrMoveBuyAtHigh(const double latestHigh, const double prevLow)
{
   if(!InpAllowBuy || !OCP_TradeOk()) return false;

   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double gap = OCP_PendingGap();
   double price = OCP_NormPrice(latestHigh);
   const double minBuy = OCP_NormPrice(ask + MathMax(gap, OCP_StopsDist() + OCP_Point()));
   if(price < minBuy)
      price = minBuy;

   const double emerg = MathMax(OCP_EmergencyDist(), OCP_StopsDist() + 2.0 * OCP_Point());
   double sl = OCP_NormPrice(price - emerg);
   if(prevLow > 0.0)
      sl = OCP_NormPrice(MathMin(sl, prevLow - gap));

   const int allowed = OCP_AllowedEntries();
   const int openN = OCP_CountPositions();
   const int pendN = OCP_CountPendings(ORDER_TYPE_BUY_STOP);
   const int room = allowed - openN;
   if(room <= 0) return false;

   ENUM_ORDER_TYPE_FILLING fill;
   OCP_SelectFilling(fill);
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFilling(fill);

   ulong ticket = 0;
   double oldPrice = 0.0;
   if(OCP_FindPending(ORDER_TYPE_BUY_STOP, ticket, oldPrice))
   {
      // one-way: only move pending UP to newer high
      if(price > oldPrice + OCP_Point() * 0.5)
      {
         if(!trade.OrderModify(ticket, price, sl, 0.0, 0))
            OCP_Log("BuyStop modify fail " + IntegerToString((int)trade.ResultRetcode()));
         else
            OCP_Log("BUY pending trail high -> " + DoubleToString(price, OCP_Digits()));
      }
      return true;
   }

   if(pendN > 0) return true;

   const int legs = MathMin(room, (openN == 0 ? MathMin(3, allowed) : 1));
   const double baseLot = OCP_CalcLot(ORDER_TYPE_BUY, price);
   if(baseLot <= 0.0) return false;
   if(g_cycle_lot <= 0.0) g_cycle_lot = baseLot;
   const double lot = OCP_NormVol(baseLot * legs);

   if(!trade.BuyStop(lot, price, g_symbol, sl, 0.0, ORDER_TIME_GTC, 0, "OCP-BUY"))
   {
      OCP_Log("BuyStop place fail " + IntegerToString((int)trade.ResultRetcode()) +
              " " + trade.ResultRetcodeDescription());
      return false;
   }
   OCP_Log("BUY pending @ high " + DoubleToString(price, OCP_Digits()) +
           " lot=" + DoubleToString(lot, 2) + " (legs=" + IntegerToString(legs) + ")" +
           " prevLow=" + DoubleToString(prevLow, OCP_Digits()));
   return true;
}

//======================================================================
// TRAIL + EMERGENCY SL
//======================================================================
void OCP_ManageTrailAndSL()
{
   const double trail = OCP_TrailDist();
   const double emerg = MathMax(OCP_EmergencyDist(), OCP_StopsDist() + 2.0 * OCP_Point());
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      const long type = PositionGetInteger(POSITION_TYPE);
      const double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl = PositionGetDouble(POSITION_SL);
      const double tp = PositionGetDouble(POSITION_TP);

      if(type == POSITION_TYPE_SELL)
      {
         // Ensure emergency SL exists above entry
         if(sl <= 0.0)
            sl = OCP_NormPrice(open + emerg);

         // Trail: if price went to 4399, SL -> 4399.5 (price + trail)
         if(bid < open) // in profit for sell
         {
            const double newSL = OCP_NormPrice(bid + trail);
            // only tighten (move down for sell SL)
            if(newSL < sl - OCP_Point() * 0.1 || sl <= 0.0)
            {
               if(newSL > bid + OCP_StopsDist())
               {
                  if(trade.PositionModify(ticket, newSL, tp))
                     OCP_Log("SELL trail SL -> " + DoubleToString(newSL, OCP_Digits()) +
                             " (bid=" + DoubleToString(bid, OCP_Digits()) + ")");
               }
            }
         }
         else if(sl <= 0.0)
         {
            trade.PositionModify(ticket, OCP_NormPrice(open + emerg), tp);
         }
      }
      else if(type == POSITION_TYPE_BUY)
      {
         if(sl <= 0.0)
            sl = OCP_NormPrice(open - emerg);

         if(ask > open) // in profit for buy
         {
            const double newSL = OCP_NormPrice(ask - trail);
            if(newSL > sl + OCP_Point() * 0.1 || sl <= 0.0)
            {
               if(newSL < ask - OCP_StopsDist())
               {
                  if(trade.PositionModify(ticket, newSL, tp))
                     OCP_Log("BUY trail SL -> " + DoubleToString(newSL, OCP_Digits()) +
                             " (ask=" + DoubleToString(ask, OCP_Digits()) + ")");
               }
            }
         }
         else if(sl <= 0.0)
         {
            trade.PositionModify(ticket, OCP_NormPrice(open - emerg), tp);
         }
      }
   }
}

//======================================================================
// MAIN LOGIC
//======================================================================
void OCP_OnNewCandle()
{
   g_profit_lock = false;
   g_cycle_lot = 0.0;
   OCP_DeletePendings(true, true);
   OCP_Log("New candle -> reset cooldown/pendings");
}

void OCP_UpdateMonitor(const ENUM_OCP_COLOR color, const double open0, const double high0, const double low0,
                       const double prevHigh, const double prevLow)
{
   const string cname = (color == OCP_RED ? "RED/SELL" : (color == OCP_GREEN ? "GREEN/BUY" : "FLAT"));
   Comment(
      "OpenColorPending v1.00\n",
      "Symbol: ", g_symbol, "\n",
      "Open: ", DoubleToString(open0, OCP_Digits()), " | Color: ", cname, "\n",
      "Curr H/L: ", DoubleToString(high0, OCP_Digits()), " / ", DoubleToString(low0, OCP_Digits()), "\n",
      "Prev H/L: ", DoubleToString(prevHigh, OCP_Digits()), " / ", DoubleToString(prevLow, OCP_Digits()), "\n",
      "Entries: ", IntegerToString(OCP_CountPositions()), "/", IntegerToString(OCP_AllowedEntries()),
      " pend=", IntegerToString(OCP_CountPendings()), "\n",
      "LotCycle: ", (g_cycle_lot > 0.0 ? DoubleToString(g_cycle_lot, 2) : "-"),
      " | Trail: ", DoubleToString(OCP_TrailDist(), OCP_Digits()), "\n",
      "ProfitLockThisCandle: ", (g_profit_lock ? "YES (wait next candle)" : "NO")
   );
}

void OCP_OnTickLogic()
{
   datetime t0, t1;
   double o0, h0, l0, c0;
   double o1, h1, l1, c1;
   if(!OCP_GetCandle(0, t0, o0, h0, l0, c0)) return;
   if(!OCP_GetCandle(1, t1, o1, h1, l1, c1)) return;

   // Previous candle high/low always detected
   const double prevHigh = h1;
   const double prevLow  = l1;

   if(t0 != g_candle_time)
   {
      g_candle_time = t0;
      OCP_OnNewCandle();
   }

   OCP_ManageTrailAndSL();

   // If already locked after profit this candle: no new pendings
   const ENUM_OCP_COLOR color = OCP_ColorFromOpen(o0);
   OCP_UpdateMonitor(color, o0, h0, l0, prevHigh, prevLow);

   if(g_profit_lock)
   {
      OCP_DeletePendings(true, true);
      return;
   }

   // If we are in profit floating heavily and closed? handled on deal. 
   // Color rules:
   // RED  -> SELL only (delete buys)
   // GREEN-> BUY only (delete sells)
   // FLAT -> delete both, wait
   if(color == OCP_RED)
   {
      OCP_DeletePendings(true, false); // no buy pending on red
      // latest low of CURRENT candle
      OCP_PlaceOrMoveSellAtLow(l0, prevHigh);
   }
   else if(color == OCP_GREEN)
   {
      OCP_DeletePendings(false, true); // no sell pending on green
      OCP_PlaceOrMoveBuyAtHigh(h0, prevLow);
   }
   else
   {
      OCP_DeletePendings(true, true);
   }
}

//======================================================================
// PROFIT COOLDOWN (after profitable close -> wait new candle)
//======================================================================
void OCP_OnDeal(const ulong deal)
{
   if(!HistoryDealSelect(deal)) return;
   if(HistoryDealGetString(deal, DEAL_SYMBOL) != g_symbol) return;
   if((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic) return;

   const long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) return;

   const double pnl = HistoryDealGetDouble(deal, DEAL_PROFIT) +
                      HistoryDealGetDouble(deal, DEAL_SWAP) +
                      HistoryDealGetDouble(deal, DEAL_COMMISSION);

   if(pnl > 0.0)
   {
      g_profit_lock = true;
      OCP_DeletePendings(true, true);
      OCP_Log("PROFIT lock this candle (pnl=" + DoubleToString(pnl, 2) + ") -> wait next candle");
   }
}

//======================================================================
int OnInit()
{
   if(!OCP_ValidateSymbol())
      return INIT_FAILED;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   ENUM_ORDER_TYPE_FILLING fill;
   OCP_SelectFilling(fill);
   trade.SetTypeFilling(fill);

   g_candle_time = 0;
   g_profit_lock = false;
   g_cycle_lot = 0.0;

   OCP_Log("Init OK OpenColorPending | dynamic lot/entries kept | trail=" +
           DoubleToString(OCP_TrailDist(), OCP_Digits()) +
           " | maxEntries=" + IntegerToString(OCP_MAX_ENTRIES));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");
   OCP_Log("Deinit " + IntegerToString(reason));
}

void OnTick()
{
   if(!g_ok) return;
   OCP_OnTickLogic();
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(request.volume < 0.0 || result.retcode == 0)
   {
      // touch params (no unused warnings)
   }
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.deal == 0) return;
   if(!HistoryDealSelect(trans.deal))
   {
      HistorySelect(TimeCurrent() - 86400, TimeCurrent() + 60);
      if(!HistoryDealSelect(trans.deal)) return;
   }
   OCP_OnDeal(trans.deal);
}
//+------------------------------------------------------------------+
