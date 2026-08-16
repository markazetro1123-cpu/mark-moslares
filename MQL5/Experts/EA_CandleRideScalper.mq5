//+------------------------------------------------------------------+
//| EA_CandleRideScalper.mq5                                         |
//| Candle Ride Scalper v1.00                                        |
//|                                                                  |
//| Ride the current candle vs its OPEN:                             |
//|   GREEN (price above open + buffer) -> BUY only                  |
//|   RED   (price below open - buffer) -> SELL only                 |
//| Color flip closes the opposite side and reverses.                |
//| Multiple market entries at the same price (not a grid).          |
//| Auto-close to lock micro profit. No trailing stop.               |
//+------------------------------------------------------------------+
#property copyright "Mark Moslares"
#property link      "https://github.com/markazetro1123-cpu/mark-moslares"
#property version   "1.00"
#property description "CandleRide v1.00: follow candle color, stack at price, auto-close lock"

#include <Trade/Trade.mqh>

//======================================================================
// CONSTANTS
//======================================================================
const int    CRS_FLAT        = 0;
const int    CRS_GREEN       = 1;
const int    CRS_RED         = 2;
const int    CRS_MAX_ENTRIES = 20;
const int    CRS_SEND_PER_TICK = 3;
const string CRS_PREFIX      = "CRS";

//======================================================================
// INPUTS
//======================================================================
input group "=== Account / Broker ==="
input long     InpMagic              = 260816; // Magic number
input double   InpMinLot             = 0.01;   // Starting lot at $10
input double   InpMaxLotCap          = 1.00;   // Maximum lot cap
input int      InpSlippagePoints     = 40;     // Deviation points
input bool     InpAllowBuy           = true;   // Allow BUY on green
input bool     InpAllowSell          = true;   // Allow SELL on red

input group "=== Candle Color ==="
input double   InpOpenBuffer         = 0.0;    // Buffer from candle open (0=auto)

input group "=== Stack / Capital ==="
input int      InpMaxEntriesCap      = 20;     // Hard cap (max 20)
input int      InpMinEntries         = 2;      // Entries at $10
input int      InpMidEntries         = 5;      // Entries at $50
input double   InpMidEquity          = 50.0;   // Equity for mid entries
input double   InpMaxEquity          = 800.0;  // Equity that reaches max entries

input group "=== Auto Close Lock (no trailing) ==="
input double   InpTriggerProfit      = 0.0;    // Arm/close when price profit >= this (0=auto)
input double   InpLockProfit         = 0.0;    // Locked price profit (0=auto)
input bool     InpPullbackLock       = true;   // true: arm at trigger, auto-close at lock; false: close at trigger
input double   InpEmergencySL        = 0.0;    // Emergency SL distance (0=auto)

input group "=== Runtime ==="
input bool     InpShowComment        = true;   // On-chart status
input bool     InpPrintLogs          = true;   // Print logs

//======================================================================
// GLOBALS
//======================================================================
CTrade   g_trade;
string   g_symbol;
bool     g_ready;
bool     g_is_gold;
bool     g_is_us30;
string   g_last_log;
datetime g_bar_time;
double   g_open_price;
int      g_color;
int      g_last_entry_color;
datetime g_skip_until;

ulong    g_armed_ticket[CRS_MAX_ENTRIES];
int      g_armed_count;

//======================================================================
// BASIC HELPERS
//======================================================================
void CRS_Log(const string message)
{
   if(!InpPrintLogs)
      return;
   if(message == g_last_log)
      return;
   g_last_log = message;
   Print("[CandleRide] ", message);
}

double CRS_Point()
{
   double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   if(point <= 0.0)
      point = _Point;
   return point;
}

int CRS_Digits()
{
   return (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
}

double CRS_NormPrice(const double price)
{
   return NormalizeDouble(price, CRS_Digits());
}

double CRS_NormVolume(double volume)
{
   double vmin  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double vmax  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   double vstep = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);

   if(vstep <= 0.0)
      vstep = 0.01;
   if(vmin <= 0.0)
      vmin = InpMinLot;

   volume = MathFloor(volume / vstep + 1e-12) * vstep;
   if(volume < vmin)
      volume = vmin;
   if(volume > vmax && vmax > 0.0)
      volume = vmax;
   if(volume < InpMinLot)
      volume = InpMinLot;
   if(volume > InpMaxLotCap)
      volume = InpMaxLotCap;

   int digits = 2;
   if(vstep < 0.01)
      digits = 3;
   if(vstep >= 1.0)
      digits = 0;
   return NormalizeDouble(volume, digits);
}

bool CRS_SelectFilling(ENUM_ORDER_TYPE_FILLING &filling)
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

void CRS_PrepareTrade()
{
   ENUM_ORDER_TYPE_FILLING filling;
   CRS_SelectFilling(filling);
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFilling(filling);
}

double CRS_StopsDistance()
{
   int stops  = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freeze = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   int level  = stops;
   if(freeze > level)
      level = freeze;
   return (double)level * CRS_Point();
}

bool CRS_TradeAllowed()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;
   if(SymbolInfoInteger(g_symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
      return false;
   return true;
}

string CRS_ToUpper(string text)
{
   StringToUpper(text);
   return text;
}

bool CRS_IsGoldSymbol(const string symbol)
{
   const string u = CRS_ToUpper(symbol);
   if(StringFind(u, "XAUUSD") >= 0)
      return true;
   if(StringFind(u, "GOLD") >= 0 && StringFind(u, "GOLDF") < 0)
      return true;
   return false;
}

bool CRS_IsUS30Symbol(const string symbol)
{
   const string u = CRS_ToUpper(symbol);
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
   if(StringFind(u, "WALL") >= 0 && StringFind(u, "30") >= 0)
      return true;
   return false;
}

bool CRS_ValidateSymbol()
{
   g_symbol  = _Symbol;
   g_is_gold = CRS_IsGoldSymbol(g_symbol);
   g_is_us30 = CRS_IsUS30Symbol(g_symbol);
   g_ready   = (g_is_gold || g_is_us30);
   if(!g_ready)
      CRS_Log("Unsupported symbol. Attach to XAUUSD / GOLD or US30 / Wall Street 30. Symbol=" + g_symbol);
   return g_ready;
}

//======================================================================
// AUTO DISTANCES / SIZING
//======================================================================
double CRS_Buffer()
{
   if(InpOpenBuffer > 0.0)
      return InpOpenBuffer;
   if(g_is_us30)
      return 1.0;
   return 0.10;
}

double CRS_TriggerProfit()
{
   if(InpTriggerProfit > 0.0)
      return InpTriggerProfit;
   if(g_is_us30)
      return 2.0;
   return 0.50;
}

double CRS_LockProfit()
{
   if(InpLockProfit > 0.0)
      return InpLockProfit;
   if(g_is_us30)
      return 1.0;
   return 0.20;
}

double CRS_EmergencyDistance()
{
   if(InpEmergencySL > 0.0)
      return InpEmergencySL;
   if(g_is_us30)
      return 40.0;
   return 5.0;
}

int CRS_ClampEntries(const int value)
{
   int n = value;
   int cap = InpMaxEntriesCap;
   if(cap < 1)
      cap = 1;
   if(cap > CRS_MAX_ENTRIES)
      cap = CRS_MAX_ENTRIES;
   if(n < 1)
      n = 1;
   if(n > cap)
      n = cap;
   return n;
}

int CRS_AllowedEntries()
{
   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   const int minN = MathMax(1, InpMinEntries);
   const int midN = MathMax(minN, InpMidEntries);
   const int maxN = CRS_ClampEntries(InpMaxEntriesCap);
   const double midEq = (InpMidEquity > 10.0 ? InpMidEquity : 50.0);
   const double maxEq = (InpMaxEquity > midEq ? InpMaxEquity : midEq + 1.0);

   int n = minN;
   if(equity <= 10.0)
      n = minN;
   else if(equity <= midEq)
   {
      const double t = (equity - 10.0) / (midEq - 10.0);
      n = (int)MathRound(minN + t * (midN - minN));
   }
   else if(equity >= maxEq)
      n = maxN;
   else
   {
      const double t = (equity - midEq) / (maxEq - midEq);
      n = (int)MathRound(midN + t * (maxN - midN));
   }
   return CRS_ClampEntries(n);
}

double CRS_LotByEquity()
{
   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double lot = InpMinLot;
   if(equity >= 25.0)
      lot = InpMinLot * 2.0;
   if(equity >= 50.0)
      lot = InpMinLot * 3.0;
   if(equity >= 100.0)
      lot = InpMinLot * 5.0;
   if(equity >= 200.0)
      lot = InpMinLot * 8.0;
   if(equity >= 400.0)
      lot = InpMinLot * 12.0;
   if(equity >= 800.0)
      lot = InpMinLot * 18.0;
   if(equity >= 1500.0)
      lot = InpMinLot * 25.0;
   if(equity >= 3000.0)
      lot = InpMinLot * 40.0;
   return lot;
}

double CRS_MaxLotByMargin(const ENUM_ORDER_TYPE orderType, const double price)
{
   const double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   const double minLot     = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   const double useMin     = (minLot > 0.0 ? minLot : InpMinLot);
   if(freeMargin <= 0.0)
      return useMin;

   double marginOneLot = 0.0;
   if(!OrderCalcMargin(orderType, g_symbol, 1.0, price, marginOneLot) || marginOneLot <= 0.0)
   {
      double marginMin = 0.0;
      if(!OrderCalcMargin(orderType, g_symbol, useMin, price, marginMin) || marginMin <= 0.0)
         return useMin;
      marginOneLot = marginMin / useMin;
   }
   return CRS_NormVolume((freeMargin * 0.65) / marginOneLot);
}

double CRS_CalcLot(const ENUM_ORDER_TYPE orderType, const double price)
{
   double lot = CRS_LotByEquity();
   lot = MathMin(lot, CRS_MaxLotByMargin(orderType, price));
   return CRS_NormVolume(lot);
}

//======================================================================
// POSITIONS
//======================================================================
bool CRS_IsOurs(const ulong ticket)
{
   if(ticket == 0 || !PositionSelectByTicket(ticket))
      return false;
   if(PositionGetString(POSITION_SYMBOL) != g_symbol)
      return false;
   if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
      return false;
   return true;
}

int CRS_CountDir(const int dir)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong ticket = PositionGetTicket(i);
      if(!CRS_IsOurs(ticket))
         continue;
      const long type = PositionGetInteger(POSITION_TYPE);
      if(dir > 0 && type == POSITION_TYPE_BUY)
         count++;
      if(dir < 0 && type == POSITION_TYPE_SELL)
         count++;
      if(dir == 0)
         count++;
   }
   return count;
}

double CRS_BasketMoney()
{
   double profit = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong ticket = PositionGetTicket(i);
      if(!CRS_IsOurs(ticket))
         continue;
      profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return profit;
}

double CRS_PriceProfit(const long type, const double openPrice)
{
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   if(type == POSITION_TYPE_BUY)
      return bid - openPrice;
   return openPrice - ask;
}

void CRS_ClearArmed()
{
   g_armed_count = 0;
   ArrayInitialize(g_armed_ticket, 0);
}

bool CRS_IsArmed(const ulong ticket)
{
   for(int i = 0; i < g_armed_count; ++i)
   {
      if(g_armed_ticket[i] == ticket)
         return true;
   }
   return false;
}

void CRS_ArmTicket(const ulong ticket)
{
   if(CRS_IsArmed(ticket))
      return;
   if(g_armed_count >= CRS_MAX_ENTRIES)
      return;
   g_armed_ticket[g_armed_count] = ticket;
   g_armed_count++;
}

void CRS_DropArmed(const ulong ticket)
{
   for(int i = 0; i < g_armed_count; ++i)
   {
      if(g_armed_ticket[i] != ticket)
         continue;
      g_armed_ticket[i] = g_armed_ticket[g_armed_count - 1];
      g_armed_ticket[g_armed_count - 1] = 0;
      g_armed_count--;
      return;
   }
}

bool CRS_CloseTicket(const ulong ticket, const string reason)
{
   if(!g_trade.PositionClose(ticket))
   {
      CRS_Log("Close failed ticket=" + IntegerToString((long)ticket) +
              " err=" + IntegerToString(GetLastError()) + " " + reason);
      return false;
   }
   CRS_DropArmed(ticket);
   return true;
}

int CRS_CloseDir(const int dir, const string reason)
{
   int closed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong ticket = PositionGetTicket(i);
      if(!CRS_IsOurs(ticket))
         continue;
      const long type = PositionGetInteger(POSITION_TYPE);
      if(dir > 0 && type != POSITION_TYPE_BUY)
         continue;
      if(dir < 0 && type != POSITION_TYPE_SELL)
         continue;
      if(CRS_CloseTicket(ticket, reason))
         closed++;
   }
   if(closed > 0)
      CRS_Log("Closed " + IntegerToString(closed) + " pos: " + reason);
   return closed;
}

//======================================================================
// CANDLE COLOR
//======================================================================
bool CRS_ReadOpen(double &openPrice)
{
   double opens[];
   ArraySetAsSeries(opens, true);
   if(CopyOpen(g_symbol, PERIOD_CURRENT, 0, 1, opens) < 1)
      return false;
   openPrice = opens[0];
   return (openPrice > 0.0);
}

int CRS_DetectColor(const double openPrice)
{
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0 || openPrice <= 0.0)
      return CRS_FLAT;

   const double mid = (bid + ask) * 0.5;
   const double buf = CRS_Buffer();
   if(mid > openPrice + buf)
      return CRS_GREEN;
   if(mid < openPrice - buf)
      return CRS_RED;
   return CRS_FLAT;
}

string CRS_ColorName(const int colorId)
{
   if(colorId == CRS_GREEN)
      return "GREEN";
   if(colorId == CRS_RED)
      return "RED";
   return "FLAT";
}

//======================================================================
// ENTRY
//======================================================================
bool CRS_SendOne(const int dir)
{
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double entry = (dir > 0 ? ask : bid);
   const double dist = MathMax(CRS_EmergencyDistance(), CRS_StopsDistance() + CRS_Point());

   double sl = 0.0;
   if(dir > 0)
      sl = CRS_NormPrice(entry - dist);
   else
      sl = CRS_NormPrice(entry + dist);

   const ENUM_ORDER_TYPE otype = (dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   const double lot = CRS_CalcLot(otype, entry);
   CRS_PrepareTrade();

   bool sent = false;
   if(dir > 0)
      sent = g_trade.Buy(lot, g_symbol, ask, sl, 0.0, CRS_PREFIX);
   else
      sent = g_trade.Sell(lot, g_symbol, bid, sl, 0.0, CRS_PREFIX);

   if(!sent)
   {
      CRS_Log("Send failed dir=" + IntegerToString(dir) +
              " err=" + IntegerToString(GetLastError()) +
              " ret=" + IntegerToString((int)g_trade.ResultRetcode()));
      return false;
   }

   g_last_entry_color = (dir > 0 ? CRS_GREEN : CRS_RED);
   CRS_Log((dir > 0 ? "BUY " : "SELL ") +
           "lot=" + DoubleToString(lot, 2) +
           " price=" + DoubleToString(entry, CRS_Digits()) +
           " sl=" + DoubleToString(sl, CRS_Digits()));
   return true;
}

void CRS_FillStack(const int dir)
{
   if(!CRS_TradeAllowed())
      return;
   if(TimeCurrent() < g_skip_until)
      return;
   if(dir > 0 && !InpAllowBuy)
      return;
   if(dir < 0 && !InpAllowSell)
      return;

   const int have = CRS_CountDir(dir);
   const int want = CRS_AllowedEntries();
   int need = want - have;
   if(need <= 0)
      return;
   if(need > CRS_SEND_PER_TICK)
      need = CRS_SEND_PER_TICK;

   for(int i = 0; i < need; ++i)
   {
      if(!CRS_SendOne(dir))
         break;
   }
}

//======================================================================
// AUTO CLOSE (no trailing)
//======================================================================
void CRS_AutoCloseLock()
{
   const double trigger = CRS_TriggerProfit();
   const double lock    = CRS_LockProfit();

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong ticket = PositionGetTicket(i);
      if(!CRS_IsOurs(ticket))
         continue;

      const long   type  = PositionGetInteger(POSITION_TYPE);
      const double openP = PositionGetDouble(POSITION_PRICE_OPEN);
      const double pp    = CRS_PriceProfit(type, openP);

      if(pp >= trigger)
         CRS_ArmTicket(ticket);

      bool closeNow = false;
      if(!InpPullbackLock)
      {
         if(pp >= trigger)
            closeNow = true;
      }
      else
      {
         if(CRS_IsArmed(ticket) && pp <= lock)
            closeNow = true;
      }

      if(!closeNow)
         continue;

      const string why = (!InpPullbackLock
                          ? "auto-close trigger"
                          : "auto-close lock");
      if(CRS_CloseTicket(ticket, why))
      {
         CRS_Log(why +
                 " ticket=" + IntegerToString((long)ticket) +
                 " move=" + DoubleToString(pp, CRS_Digits()));
         g_skip_until = TimeCurrent() + 1;
      }
   }
}

//======================================================================
// DRIVE
//======================================================================
void CRS_OnColor(const int colorId)
{
   if(colorId == CRS_GREEN)
   {
      if(CRS_CountDir(-1) > 0)
         CRS_CloseDir(-1, "flip to GREEN");
      CRS_FillStack(1);
      return;
   }
   if(colorId == CRS_RED)
   {
      if(CRS_CountDir(1) > 0)
         CRS_CloseDir(1, "flip to RED");
      CRS_FillStack(-1);
   }
}

void CRS_UpdateComment()
{
   if(!InpShowComment)
      return;

   Comment(
      "Candle Ride Scalper v1.00\n",
      "symbol: ", g_symbol, "\n",
      "open: ", DoubleToString(g_open_price, CRS_Digits()),
      "  color: ", CRS_ColorName(g_color), "\n",
      "buys: ", IntegerToString(CRS_CountDir(1)),
      "  sells: ", IntegerToString(CRS_CountDir(-1)),
      "  allow: ", IntegerToString(CRS_AllowedEntries()), "\n",
      "last entry: ", CRS_ColorName(g_last_entry_color), "\n",
      "lot: ", DoubleToString(CRS_LotByEquity(), 2),
      "  equity: ", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2), "\n",
      "trigger: ", DoubleToString(CRS_TriggerProfit(), CRS_Digits()),
      "  lock: ", DoubleToString(CRS_LockProfit(), CRS_Digits()),
      (InpPullbackLock ? "  mode: pullback-lock" : "  mode: close-at-trigger"), "\n",
      "basket $: ", DoubleToString(CRS_BasketMoney(), 2)
   );
}

//======================================================================
// EVENTS
//======================================================================
int OnInit()
{
   g_symbol           = _Symbol;
   g_ready            = false;
   g_last_log         = "";
   g_bar_time         = 0;
   g_open_price       = 0.0;
   g_color            = CRS_FLAT;
   g_last_entry_color = CRS_FLAT;
   g_skip_until       = 0;
   CRS_ClearArmed();

   if(!CRS_ValidateSymbol())
      return INIT_FAILED;
   if(InpMinEntries < 1)
   {
      CRS_Log("InpMinEntries must be >= 1");
      return INIT_FAILED;
   }
   if(InpMaxEntriesCap < InpMinEntries)
   {
      CRS_Log("InpMaxEntriesCap must be >= InpMinEntries");
      return INIT_FAILED;
   }

   CRS_PrepareTrade();
   CRS_Log("Ready on " + g_symbol + " TF=" + EnumToString(_Period) +
           " trigger=" + DoubleToString(CRS_TriggerProfit(), CRS_Digits()) +
           " lock=" + DoubleToString(CRS_LockProfit(), CRS_Digits()));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");
}

void OnTick()
{
   if(!g_ready)
      return;

   CRS_PrepareTrade();
   CRS_AutoCloseLock();

   double openPrice = 0.0;
   if(!CRS_ReadOpen(openPrice))
      return;
   g_open_price = openPrice;

   const datetime barTime = iTime(g_symbol, PERIOD_CURRENT, 0);
   if(barTime > 0 && barTime != g_bar_time)
   {
      g_bar_time = barTime;
      g_color    = CRS_FLAT;
      CRS_Log("New candle open=" + DoubleToString(openPrice, CRS_Digits()));
   }

   g_color = CRS_DetectColor(openPrice);
   if(g_color != CRS_FLAT)
      CRS_OnColor(g_color);

   CRS_UpdateComment();
}
