//+------------------------------------------------------------------+
//| EA_NYSweepHunter.mq5                                             |
//| NY Liquidity Sweep Hunter v1.00                                  |
//|                                                                  |
//| Marks the Asian range, then during NY (default PH 20:00-05:00)   |
//| waits for a liquidity sweep of that high/low and fades it.       |
//| Chart symbol = work symbol. Tuned for XAUUSD and US30/WST30.     |
//+------------------------------------------------------------------+
#property copyright "Mark Moslares"
#property link      "https://github.com/markazetro1123-cpu/mark-moslares"
#property version   "1.00"
#property description "NYSweepHunter v1.00: Asian-range liquidity sweep reversal for XAUUSD + US30"

#include <Trade/Trade.mqh>

//======================================================================
// ENUMS
//======================================================================
enum ENUM_NSH_ENTRY_MODE
{
   NSH_ENTRY_MARKET    = 0, // Market on confirmed sweep close
   NSH_ENTRY_LIMIT_MID = 1  // Limit at midpoint of the sweep candle
};

enum ENUM_NSH_TP_MODE
{
   NSH_TP_RR             = 0, // Take profit by risk:reward
   NSH_TP_OPPOSITE_RANGE = 1  // Take profit at the opposite range side
};

//======================================================================
// INPUTS
//======================================================================
input group "=== Account / Broker ==="
input long     InpMagic              = 260813; // Magic number
input double   InpRiskPercent        = 2.0;    // Risk % of equity (0 = use min lot)
input double   InpFixedLot           = 0.0;    // Fixed lot (0 = risk-based)
input double   InpMinLot             = 0.01;   // Minimum lot
input double   InpMaxLotCap          = 1.00;   // Maximum lot cap
input int      InpSlippagePoints     = 40;     // Deviation points
input int      InpMaxPositions       = 1;      // Max open positions
input bool     InpAllowBuy           = true;   // Allow BUY after low sweep
input bool     InpAllowSell          = true;   // Allow SELL after high sweep

input group "=== Session Clock (PH default) ==="
input bool     InpUseSessionFilter   = true;   // Enable NY trade window
input int      InpSessionTZOffsetHrs = 8;      // Local TZ vs GMT (PH=8)
input int      InpSessionStartHour   = 20;     // Trade start hour
input int      InpSessionStartMinute = 0;      // Trade start minute
input int      InpSessionEndHour     = 5;      // Trade end hour
input int      InpSessionEndMinute   = 0;      // Trade end minute

input group "=== Asian Range Window ==="
input int      InpRangeStartHour     = 8;      // Range start hour (local)
input int      InpRangeStartMinute   = 0;      // Range start minute
input int      InpRangeEndHour       = 16;     // Range end hour (local)
input int      InpRangeEndMinute     = 0;      // Range end minute
input int      InpMinRangeBars       = 8;      // Minimum bars inside the range

input group "=== Sweep Rules ==="
input double   InpMinSweep           = 0.0;    // Min pierce beyond range (0=auto)
input double   InpMaxSweep           = 0.0;    // Max pierce (0=off, skip huge spikes)
input bool     InpRequireCloseInside = true;   // Sweep candle must close back inside
input bool     InpOneSweepPerSide    = true;   // One trade per side per range day
input bool     InpAllowBreakout      = false;  // Also trade close-outside breakouts
input int      InpCooldownMinutes    = 5;      // Wait after a close before next entry

input group "=== Entry / Exits ==="
input ENUM_NSH_ENTRY_MODE InpEntryMode = NSH_ENTRY_MARKET; // Entry style
input ENUM_NSH_TP_MODE    InpTPMode    = NSH_TP_RR;        // Take-profit style
input double   InpRR                 = 1.5;    // Risk:reward when TP mode = RR
input double   InpSLBuffer           = 0.0;    // Extra SL beyond sweep wick (0=auto)
input int      InpLimitExpireBars    = 8;      // Limit order lifetime in bars
input double   InpEmergencySL        = 0.0;    // Hard SL distance (0=auto)

input group "=== Secure / Basket ==="
input double   InpSecureTrigger      = 0.0;    // Arm lock when floating >= this (0=auto)
input double   InpSecureLock         = 0.0;    // Locked profit once armed (0=auto)
input double   InpTrailStep          = 0.0;    // Trail step after lock (0=use lock)
input bool     InpUseBasketClose     = true;   // Close all when basket is green
input double   InpBasketProfit       = 0.0;    // Basket close profit (0=auto)

input group "=== News Blackout (PH clock) ==="
input bool     InpUseNewsBlackout    = true;   // Skip new entries near US news
input int      InpNews1Hour          = 20;     // First blackout hour
input int      InpNews1Minute        = 30;     // First blackout minute
input int      InpNews2Hour          = 21;     // Second blackout hour
input int      InpNews2Minute        = 30;     // Second blackout minute
input int      InpNewsWindowMinutes  = 10;     // Blackout length in minutes

input group "=== Runtime ==="
input int      InpMaxSpreadPoints    = 0;      // Max spread in points (0=off)
input bool     InpDrawRange          = true;   // Draw range high/low on chart
input bool     InpShowComment        = true;   // On-chart status comment
input bool     InpPrintLogs          = true;   // Print logs

//======================================================================
// CONSTANTS
//======================================================================
const string NSH_PREFIX     = "NSH";
const string NSH_LINE_HIGH  = "NSH_RANGE_HIGH";
const string NSH_LINE_LOW   = "NSH_RANGE_LOW";
const int    NSH_SCAN_BARS  = 900;

//======================================================================
// GLOBALS
//======================================================================
CTrade   g_trade;
string   g_symbol;
bool     g_ready;
bool     g_is_gold;
bool     g_is_us30;
datetime g_bar_time;
datetime g_cooldown_until;
string   g_last_log;

bool     g_range_ready;
datetime g_range_day;
double   g_range_high;
double   g_range_low;
int      g_range_bars;

bool     g_used_buy_side;
bool     g_used_sell_side;
datetime g_used_side_day;

datetime g_setup_bar;
int      g_setup_dir;       // 1 = buy, -1 = sell
double   g_setup_high;
double   g_setup_low;
bool     g_setup_is_breakout;

ulong    g_limit_ticket;
datetime g_limit_bar_time;
int      g_limit_bars_left;
int      g_limit_dir;

//======================================================================
// BASIC HELPERS
//======================================================================
void NSH_Log(const string message)
{
   if(!InpPrintLogs)
      return;
   if(message == g_last_log)
      return;
   g_last_log = message;
   Print("[NYSweep] ", message);
}

double NSH_Point()
{
   double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   if(point <= 0.0)
      point = _Point;
   return point;
}

int NSH_Digits()
{
   return (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
}

double NSH_NormPrice(const double price)
{
   return NormalizeDouble(price, NSH_Digits());
}

double NSH_NormVolume(double volume)
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

bool NSH_SelectFilling(ENUM_ORDER_TYPE_FILLING &filling)
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

void NSH_PrepareTrade()
{
   ENUM_ORDER_TYPE_FILLING filling;
   NSH_SelectFilling(filling);
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFilling(filling);
}

double NSH_StopsDistance()
{
   int stops  = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freeze = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   int level  = stops;
   if(freeze > level)
      level = freeze;
   return (double)level * NSH_Point();
}

bool NSH_TradeAllowed()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;
   if(SymbolInfoInteger(g_symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
      return false;
   return true;
}

string NSH_ToUpper(string text)
{
   StringToUpper(text);
   return text;
}

bool NSH_IsGoldSymbol(const string symbol)
{
   const string u = NSH_ToUpper(symbol);
   if(StringFind(u, "XAUUSD") >= 0)
      return true;
   if(StringFind(u, "GOLD") >= 0 && StringFind(u, "GOLDF") < 0)
      return true;
   return false;
}

bool NSH_IsUS30Symbol(const string symbol)
{
   const string u = NSH_ToUpper(symbol);
   if(StringFind(u, "US30") >= 0)
      return true;
   if(StringFind(u, "DJ30") >= 0)
      return true;
   if(StringFind(u, "DJIA") >= 0)
      return true;
   if(StringFind(u, "WALLSTREET30") >= 0)
      return true;
   if(StringFind(u, "WALL STREET 30") >= 0)
      return true;
   if(StringFind(u, "WALL") >= 0 && StringFind(u, "30") >= 0)
      return true;
   if(StringFind(u, "WST30") >= 0)
      return true;
   if(StringFind(u, "DOWJONES") >= 0)
      return true;
   return false;
}

bool NSH_ValidateSymbol()
{
   g_symbol  = _Symbol;
   g_is_gold = NSH_IsGoldSymbol(g_symbol);
   g_is_us30 = NSH_IsUS30Symbol(g_symbol);
   g_ready   = (g_is_gold || g_is_us30);
   if(!g_ready)
      NSH_Log("Unsupported symbol. Attach to XAUUSD / GOLD or US30 / Wall Street 30. Symbol=" + g_symbol);
   return g_ready;
}

//======================================================================
// AUTO DISTANCES
//======================================================================
double NSH_AutoMinSweep()
{
   if(InpMinSweep > 0.0)
      return InpMinSweep;
   if(g_is_us30)
      return 5.0;
   return 0.50;
}

double NSH_AutoMaxSweep()
{
   if(InpMaxSweep > 0.0)
      return InpMaxSweep;
   return 0.0;
}

double NSH_AutoSLBuffer()
{
   if(InpSLBuffer > 0.0)
      return InpSLBuffer;
   if(g_is_us30)
      return 3.0;
   return 0.30;
}

double NSH_EmergencyDistance()
{
   if(InpEmergencySL > 0.0)
      return InpEmergencySL;
   if(g_is_us30)
      return 40.0;
   return 5.0;
}

double NSH_SecureTrigger()
{
   if(InpSecureTrigger > 0.0)
      return InpSecureTrigger;
   if(g_is_us30)
      return 1.0;
   return 0.20;
}

double NSH_SecureLock()
{
   if(InpSecureLock > 0.0)
      return InpSecureLock;
   if(g_is_us30)
      return 1.0;
   return 0.20;
}

double NSH_TrailStep()
{
   if(InpTrailStep > 0.0)
      return InpTrailStep;
   return NSH_SecureLock();
}

double NSH_BasketTarget()
{
   if(InpBasketProfit > 0.0)
      return InpBasketProfit;
   if(g_is_us30)
      return 1.5;
   return 0.40;
}

//======================================================================
// CLOCK
//======================================================================
datetime NSH_ServerToLocal(const datetime serverTime)
{
   const datetime gmtOffset = TimeGMT() - TimeCurrent();
   return serverTime + gmtOffset + (datetime)(InpSessionTZOffsetHrs * 3600);
}

int NSH_LocalMinuteOfDay(const datetime localTime)
{
   MqlDateTime dt;
   TimeToStruct(localTime, dt);
   return dt.hour * 60 + dt.min;
}

datetime NSH_LocalNow()
{
   return NSH_ServerToLocal(TimeCurrent());
}

datetime NSH_LocalDayStamp(const datetime localTime)
{
   MqlDateTime dt;
   TimeToStruct(localTime, dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   return StructToTime(dt);
}

bool NSH_InMinuteWindow(const int nowMin, const int startMin, const int endMin)
{
   if(startMin == endMin)
      return true;
   if(startMin < endMin)
      return (nowMin >= startMin && nowMin < endMin);
   return (nowMin >= startMin || nowMin < endMin);
}

bool NSH_SessionOK()
{
   if(!InpUseSessionFilter)
      return true;
   const int nowMin = NSH_LocalMinuteOfDay(NSH_LocalNow());
   const int a = InpSessionStartHour * 60 + InpSessionStartMinute;
   const int b = InpSessionEndHour * 60 + InpSessionEndMinute;
   return NSH_InMinuteWindow(nowMin, a, b);
}

bool NSH_InNewsBlackout()
{
   if(!InpUseNewsBlackout)
      return false;

   const int nowMin = NSH_LocalMinuteOfDay(NSH_LocalNow());
   const int n1 = InpNews1Hour * 60 + InpNews1Minute;
   const int n2 = InpNews2Hour * 60 + InpNews2Minute;
   const int win = MathMax(1, InpNewsWindowMinutes);

   if(nowMin >= n1 && nowMin < n1 + win)
      return true;
   if(nowMin >= n2 && nowMin < n2 + win)
      return true;
   return false;
}

datetime NSH_ActiveRangeDay()
{
   const datetime local = NSH_LocalNow();
   const int nowMin = NSH_LocalMinuteOfDay(local);
   const int tradeStart = InpSessionStartHour * 60 + InpSessionStartMinute;
   const int tradeEnd   = InpSessionEndHour * 60 + InpSessionEndMinute;
   datetime day = NSH_LocalDayStamp(local);

   // Overnight NY tail (after midnight, before session end) uses yesterday's Asian range.
   if(tradeStart > tradeEnd && nowMin < tradeEnd)
      day -= 86400;
   return day;
}

bool NSH_RangeWindowClosed(const datetime rangeDay)
{
   const datetime local = NSH_LocalNow();
   const datetime localDay = NSH_LocalDayStamp(local);
   if(localDay > rangeDay)
      return true;
   if(localDay < rangeDay)
      return false;
   const int nowMin = NSH_LocalMinuteOfDay(local);
   const int rangeEnd = InpRangeEndHour * 60 + InpRangeEndMinute;
   return (nowMin >= rangeEnd);
}

//======================================================================
// LOT
//======================================================================
double NSH_LossPerLot(const double distance)
{
   if(distance <= 0.0)
      return 0.0;
   const double tickSize  = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
   const double tickValue = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0)
      return 0.0;
   return (distance / tickSize) * tickValue;
}

double NSH_MaxLotByMargin(const ENUM_ORDER_TYPE orderType, const double price)
{
   const double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   const double minLot     = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   if(freeMargin <= 0.0)
      return (minLot > 0.0 ? minLot : InpMinLot);

   double marginOneLot = 0.0;
   if(!OrderCalcMargin(orderType, g_symbol, 1.0, price, marginOneLot) || marginOneLot <= 0.0)
   {
      double marginMin = 0.0;
      const double useMin = (minLot > 0.0 ? minLot : InpMinLot);
      if(!OrderCalcMargin(orderType, g_symbol, useMin, price, marginMin) || marginMin <= 0.0)
         return useMin;
      marginOneLot = marginMin / useMin;
   }
   return NSH_NormVolume((freeMargin * 0.65) / marginOneLot);
}

double NSH_CalcLot(const ENUM_ORDER_TYPE orderType, const double price, const double slDistance)
{
   if(InpFixedLot > 0.0)
      return NSH_NormVolume(MathMin(InpFixedLot, NSH_MaxLotByMargin(orderType, price)));

   double lot = InpMinLot;
   if(InpRiskPercent > 0.0)
   {
      const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      const double lossPerLot = NSH_LossPerLot(slDistance);
      if(lossPerLot > 0.0)
         lot = (equity * InpRiskPercent / 100.0) / lossPerLot;
   }

   lot = MathMin(lot, NSH_MaxLotByMargin(orderType, price));
   return NSH_NormVolume(lot);
}

//======================================================================
// COUNTS / MONEY
//======================================================================
int NSH_CountPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      count++;
   }
   return count;
}

double NSH_BasketProfit()
{
   double profit = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      profit += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return profit;
}

bool NSH_CloseAll(const string reason)
{
   bool ok = true;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if(!g_trade.PositionClose(ticket))
      {
         ok = false;
         NSH_Log("Close failed ticket=" + IntegerToString((long)ticket) + " err=" + IntegerToString(GetLastError()));
      }
   }
   if(ok)
   {
      g_cooldown_until = TimeCurrent() + InpCooldownMinutes * 60;
      NSH_Log("Closed basket: " + reason);
   }
   return ok;
}

void NSH_CancelPendings()
{
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != g_symbol)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      g_trade.OrderDelete(ticket);
   }
   g_limit_ticket = 0;
   g_limit_dir    = 0;
}

//======================================================================
// RANGE
//======================================================================
bool NSH_BuildRange(const datetime rangeDay)
{
   datetime times[];
   double   highs[];
   double   lows[];
   ArraySetAsSeries(times, true);
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);

   const int copied = CopyTime(g_symbol, PERIOD_CURRENT, 0, NSH_SCAN_BARS, times);
   if(copied < InpMinRangeBars)
      return false;
   if(CopyHigh(g_symbol, PERIOD_CURRENT, 0, copied, highs) < copied)
      return false;
   if(CopyLow(g_symbol, PERIOD_CURRENT, 0, copied, lows) < copied)
      return false;

   const int rangeStartMin = InpRangeStartHour * 60 + InpRangeStartMinute;
   const int rangeEndMin   = InpRangeEndHour * 60 + InpRangeEndMinute;

   double hi = -1.0e100;
   double lo =  1.0e100;
   int    bars = 0;

   for(int i = 0; i < copied; ++i)
   {
      const datetime local = NSH_ServerToLocal(times[i]);
      if(NSH_LocalDayStamp(local) != rangeDay)
         continue;
      const int minute = NSH_LocalMinuteOfDay(local);
      if(!NSH_InMinuteWindow(minute, rangeStartMin, rangeEndMin))
         continue;
      if(highs[i] > hi)
         hi = highs[i];
      if(lows[i] < lo)
         lo = lows[i];
      bars++;
   }

   if(bars < InpMinRangeBars || hi <= lo)
      return false;

   g_range_ready = true;
   g_range_day   = rangeDay;
   g_range_high  = NSH_NormPrice(hi);
   g_range_low   = NSH_NormPrice(lo);
   g_range_bars  = bars;

   if(g_used_side_day != rangeDay)
   {
      g_used_buy_side  = false;
      g_used_sell_side = false;
      g_used_side_day  = rangeDay;
   }
   return true;
}

void NSH_UpdateRange(const bool allowRebuild)
{
   const datetime day = NSH_ActiveRangeDay();
   if(g_range_day != day)
   {
      g_range_ready = false;
      g_range_day   = day;
      g_range_bars  = 0;
   }

   const bool closed = NSH_RangeWindowClosed(day);
   if(g_range_ready && closed)
      return;
   if(!allowRebuild && g_range_bars > 0)
      return;

   if(!NSH_BuildRange(day))
   {
      if(closed)
         g_range_ready = false;
      return;
   }

   // Do not lock a forming Asian range for live entries.
   if(!closed)
      g_range_ready = false;

   if(g_range_ready)
      NSH_Log("Range ready day=" + TimeToString(day, TIME_DATE) +
              " high=" + DoubleToString(g_range_high, NSH_Digits()) +
              " low=" + DoubleToString(g_range_low, NSH_Digits()) +
              " bars=" + IntegerToString(g_range_bars));
}

void NSH_DrawRange()
{
   if(!InpDrawRange || g_range_high <= g_range_low || g_range_bars <= 0)
      return;

   if(ObjectFind(0, NSH_LINE_HIGH) < 0)
      ObjectCreate(0, NSH_LINE_HIGH, OBJ_HLINE, 0, 0, g_range_high);
   ObjectSetDouble(0, NSH_LINE_HIGH, OBJPROP_PRICE, g_range_high);
   ObjectSetInteger(0, NSH_LINE_HIGH, OBJPROP_COLOR, clrDodgerBlue);
   ObjectSetInteger(0, NSH_LINE_HIGH, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, NSH_LINE_HIGH, OBJPROP_WIDTH, 1);
   ObjectSetString(0, NSH_LINE_HIGH, OBJPROP_TEXT, "NSH range high");

   if(ObjectFind(0, NSH_LINE_LOW) < 0)
      ObjectCreate(0, NSH_LINE_LOW, OBJ_HLINE, 0, 0, g_range_low);
   ObjectSetDouble(0, NSH_LINE_LOW, OBJPROP_PRICE, g_range_low);
   ObjectSetInteger(0, NSH_LINE_LOW, OBJPROP_COLOR, clrOrangeRed);
   ObjectSetInteger(0, NSH_LINE_LOW, OBJPROP_STYLE, STYLE_DASH);
   ObjectSetInteger(0, NSH_LINE_LOW, OBJPROP_WIDTH, 1);
   ObjectSetString(0, NSH_LINE_LOW, OBJPROP_TEXT, "NSH range low");
}

void NSH_ClearDrawings()
{
   ObjectDelete(0, NSH_LINE_HIGH);
   ObjectDelete(0, NSH_LINE_LOW);
}

//======================================================================
// BARS
//======================================================================
bool NSH_CopyClosedBar(datetime &barTime, double &openPrice, double &highPrice, double &lowPrice, double &closePrice)
{
   datetime times[];
   double opens[], highs[], lows[], closes[];
   ArraySetAsSeries(times, true);
   ArraySetAsSeries(opens, true);
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);
   ArraySetAsSeries(closes, true);

   if(CopyTime(g_symbol, PERIOD_CURRENT, 1, 1, times) < 1)
      return false;
   if(CopyOpen(g_symbol, PERIOD_CURRENT, 1, 1, opens) < 1)
      return false;
   if(CopyHigh(g_symbol, PERIOD_CURRENT, 1, 1, highs) < 1)
      return false;
   if(CopyLow(g_symbol, PERIOD_CURRENT, 1, 1, lows) < 1)
      return false;
   if(CopyClose(g_symbol, PERIOD_CURRENT, 1, 1, closes) < 1)
      return false;

   barTime    = times[0];
   openPrice  = opens[0];
   highPrice  = highs[0];
   lowPrice   = lows[0];
   closePrice = closes[0];
   return true;
}

bool NSH_NewBar()
{
   const datetime t = iTime(g_symbol, PERIOD_CURRENT, 0);
   if(t <= 0)
      return false;
   if(t == g_bar_time)
      return false;
   g_bar_time = t;
   return true;
}

bool NSH_SpreadOK()
{
   if(InpMaxSpreadPoints <= 0)
      return true;
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double point = NSH_Point();
   if(point <= 0.0 || ask <= 0.0 || bid <= 0.0)
      return false;
   const int spread = (int)MathRound((ask - bid) / point);
   return (spread <= InpMaxSpreadPoints);
}

//======================================================================
// SETUP DETECT
//======================================================================
void NSH_ResetSetup()
{
   g_setup_bar        = 0;
   g_setup_dir        = 0;
   g_setup_high       = 0.0;
   g_setup_low        = 0.0;
   g_setup_is_breakout = false;
}

bool NSH_DetectSetup()
{
   if(!g_range_ready)
      return false;

   datetime barTime;
   double openPrice, highPrice, lowPrice, closePrice;
   if(!NSH_CopyClosedBar(barTime, openPrice, highPrice, lowPrice, closePrice))
      return false;
   if(barTime == g_setup_bar)
      return (g_setup_dir != 0);

   NSH_ResetSetup();

   const double minSweep = NSH_AutoMinSweep();
   const double maxSweep = NSH_AutoMaxSweep();
   const double pierceHigh = highPrice - g_range_high;
   const double pierceLow  = g_range_low - lowPrice;

   bool sellSweep = (pierceHigh >= minSweep);
   bool buySweep  = (pierceLow >= minSweep);

   if(maxSweep > 0.0)
   {
      if(pierceHigh > maxSweep)
         sellSweep = false;
      if(pierceLow > maxSweep)
         buySweep = false;
   }

   if(InpRequireCloseInside)
   {
      if(closePrice >= g_range_high)
         sellSweep = false;
      if(closePrice <= g_range_low)
         buySweep = false;
   }

   bool sellBreak = false;
   bool buyBreak  = false;
   if(InpAllowBreakout)
   {
      sellBreak = (closePrice > g_range_high && pierceHigh >= minSweep);
      buyBreak  = (closePrice < g_range_low && pierceLow >= minSweep);
   }

   if(sellSweep && InpAllowSell)
   {
      g_setup_bar  = barTime;
      g_setup_dir  = -1;
      g_setup_high = highPrice;
      g_setup_low  = lowPrice;
      g_setup_is_breakout = false;
      NSH_Log("SELL sweep high=" + DoubleToString(highPrice, NSH_Digits()) +
              " close=" + DoubleToString(closePrice, NSH_Digits()) +
              " rangeHigh=" + DoubleToString(g_range_high, NSH_Digits()));
      return true;
   }
   if(buySweep && InpAllowBuy)
   {
      g_setup_bar  = barTime;
      g_setup_dir  = 1;
      g_setup_high = highPrice;
      g_setup_low  = lowPrice;
      g_setup_is_breakout = false;
      NSH_Log("BUY sweep low=" + DoubleToString(lowPrice, NSH_Digits()) +
              " close=" + DoubleToString(closePrice, NSH_Digits()) +
              " rangeLow=" + DoubleToString(g_range_low, NSH_Digits()));
      return true;
   }
   if(sellBreak && InpAllowSell)
   {
      g_setup_bar  = barTime;
      g_setup_dir  = -1;
      g_setup_high = highPrice;
      g_setup_low  = lowPrice;
      g_setup_is_breakout = true;
      NSH_Log("SELL breakout close=" + DoubleToString(closePrice, NSH_Digits()));
      return true;
   }
   if(buyBreak && InpAllowBuy)
   {
      g_setup_bar  = barTime;
      g_setup_dir  = 1;
      g_setup_high = highPrice;
      g_setup_low  = lowPrice;
      g_setup_is_breakout = true;
      NSH_Log("BUY breakout close=" + DoubleToString(closePrice, NSH_Digits()));
      return true;
   }
   return false;
}

//======================================================================
// SL / TP
//======================================================================
bool NSH_BuildStops(const int dir, const double entry, double &sl, double &tp)
{
   const double buffer = NSH_AutoSLBuffer();
   const double stops  = NSH_StopsDistance();
   const double emergency = NSH_EmergencyDistance();

   if(dir > 0)
   {
      sl = g_setup_low - buffer;
      if((entry - sl) < stops)
         sl = entry - MathMax(stops, buffer);
      if((entry - sl) > emergency && emergency > 0.0)
         sl = entry - emergency;
   }
   else
   {
      sl = g_setup_high + buffer;
      if((sl - entry) < stops)
         sl = entry + MathMax(stops, buffer);
      if((sl - entry) > emergency && emergency > 0.0)
         sl = entry + emergency;
   }

   const double risk = MathAbs(entry - sl);
   if(risk <= 0.0)
      return false;

   if(InpTPMode == NSH_TP_OPPOSITE_RANGE && g_range_ready)
   {
      if(dir > 0)
         tp = g_range_high;
      else
         tp = g_range_low;

      const double reward = MathAbs(tp - entry);
      if(reward < risk * 0.5)
      {
         if(dir > 0)
            tp = entry + risk * InpRR;
         else
            tp = entry - risk * InpRR;
      }
   }
   else
   {
      const double rr = (InpRR > 0.0 ? InpRR : 1.0);
      if(dir > 0)
         tp = entry + risk * rr;
      else
         tp = entry - risk * rr;
   }

   if(dir > 0 && (tp - entry) < stops)
      tp = entry + stops;
   if(dir < 0 && (entry - tp) < stops)
      tp = entry - stops;

   sl = NSH_NormPrice(sl);
   tp = NSH_NormPrice(tp);
   if(dir > 0 && !(sl < entry && tp > entry))
      return false;
   if(dir < 0 && !(sl > entry && tp < entry))
      return false;
   return true;
}

//======================================================================
// ENTRY
//======================================================================
bool NSH_CanEnter(const int dir)
{
   if(!g_ready || !NSH_TradeAllowed() || !NSH_SessionOK())
      return false;
   if(NSH_InNewsBlackout())
      return false;
   if(!NSH_SpreadOK())
      return false;
   if(TimeCurrent() < g_cooldown_until)
      return false;
   if(NSH_CountPositions() >= InpMaxPositions)
      return false;
   if(InpOneSweepPerSide)
   {
      if(dir > 0 && g_used_buy_side)
         return false;
      if(dir < 0 && g_used_sell_side)
         return false;
   }
   return true;
}

void NSH_MarkSideUsed(const int dir)
{
   if(dir > 0)
      g_used_buy_side = true;
   if(dir < 0)
      g_used_sell_side = true;
   g_used_side_day = g_range_day;
}

bool NSH_SendMarket(const int dir)
{
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double entry = (dir > 0 ? ask : bid);
   double sl = 0.0;
   double tp = 0.0;
   if(!NSH_BuildStops(dir, entry, sl, tp))
   {
      NSH_Log("Skip: invalid SL/TP at market");
      return false;
   }

   const double slDist = MathAbs(entry - sl);
   const ENUM_ORDER_TYPE otype = (dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   const double lot = NSH_CalcLot(otype, entry, slDist);
   NSH_PrepareTrade();

   bool sent = false;
   if(dir > 0)
      sent = g_trade.Buy(lot, g_symbol, ask, sl, tp, NSH_PREFIX);
   else
      sent = g_trade.Sell(lot, g_symbol, bid, sl, tp, NSH_PREFIX);

   if(!sent)
   {
      NSH_Log("Market send failed err=" + IntegerToString(GetLastError()) +
              " ret=" + IntegerToString((int)g_trade.ResultRetcode()));
      return false;
   }

   NSH_MarkSideUsed(dir);
   NSH_Log((dir > 0 ? "BUY" : "SELL") +
           " market lot=" + DoubleToString(lot, 2) +
           " sl=" + DoubleToString(sl, NSH_Digits()) +
           " tp=" + DoubleToString(tp, NSH_Digits()));
   return true;
}

bool NSH_SendLimit(const int dir)
{
   const double mid = NSH_NormPrice((g_setup_high + g_setup_low) * 0.5);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double stops = NSH_StopsDistance();

   if(dir > 0 && mid >= ask - stops)
      return NSH_SendMarket(dir);
   if(dir < 0 && mid <= bid + stops)
      return NSH_SendMarket(dir);

   double sl = 0.0;
   double tp = 0.0;
   if(!NSH_BuildStops(dir, mid, sl, tp))
      return NSH_SendMarket(dir);

   const double slDist = MathAbs(mid - sl);
   const ENUM_ORDER_TYPE otype = (dir > 0 ? ORDER_TYPE_BUY_LIMIT : ORDER_TYPE_SELL_LIMIT);
   const double lot = NSH_CalcLot(otype, mid, slDist);
   NSH_PrepareTrade();
   NSH_CancelPendings();

   bool sent = false;
   if(dir > 0)
      sent = g_trade.BuyLimit(lot, mid, g_symbol, sl, tp, ORDER_TIME_GTC, 0, NSH_PREFIX);
   else
      sent = g_trade.SellLimit(lot, mid, g_symbol, sl, tp, ORDER_TIME_GTC, 0, NSH_PREFIX);

   if(!sent)
   {
      NSH_Log("Limit send failed, fallback market. err=" + IntegerToString(GetLastError()));
      return NSH_SendMarket(dir);
   }

   g_limit_ticket    = g_trade.ResultOrder();
   g_limit_bar_time  = g_bar_time;
   g_limit_bars_left = InpLimitExpireBars;
   g_limit_dir       = dir;
   NSH_MarkSideUsed(dir);
   NSH_Log((dir > 0 ? "BUY" : "SELL") +
           " limit mid=" + DoubleToString(mid, NSH_Digits()) +
           " lot=" + DoubleToString(lot, 2));
   return true;
}

void NSH_AgeLimit()
{
   if(g_limit_ticket == 0)
      return;
   if(!OrderSelect(g_limit_ticket))
   {
      g_limit_ticket = 0;
      g_limit_dir = 0;
      return;
   }
   if(g_bar_time != g_limit_bar_time)
   {
      g_limit_bar_time = g_bar_time;
      g_limit_bars_left--;
   }
   if(g_limit_bars_left <= 0)
   {
      NSH_Log("Limit expired, deleting");
      NSH_CancelPendings();
   }
}

void NSH_TryEnter()
{
   if(g_setup_dir == 0)
      return;
   if(!NSH_CanEnter(g_setup_dir))
      return;

   if(InpEntryMode == NSH_ENTRY_LIMIT_MID && !g_setup_is_breakout)
      NSH_SendLimit(g_setup_dir);
   else
      NSH_SendMarket(g_setup_dir);

   NSH_ResetSetup();
}

//======================================================================
// MANAGE OPEN TRADES
//======================================================================
void NSH_ManageOpen()
{
   if(NSH_CountPositions() <= 0)
      return;

   if(InpUseBasketClose && NSH_BasketProfit() >= NSH_BasketTarget())
   {
      NSH_CloseAll("basket green");
      return;
   }

   const double trigger = NSH_SecureTrigger();
   const double lock    = NSH_SecureLock();
   const double step    = NSH_TrailStep();
   const double bid     = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask     = SymbolInfoDouble(g_symbol, SYMBOL_ASK);

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      const long   type   = PositionGetInteger(POSITION_TYPE);
      const double open   = PositionGetDouble(POSITION_PRICE_OPEN);
      const double sl     = PositionGetDouble(POSITION_SL);
      const double tp     = PositionGetDouble(POSITION_TP);
      const double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

      if(profit < trigger)
         continue;

      double newSL = sl;
      if(type == POSITION_TYPE_BUY)
      {
         const double lockSL = open + lock;
         if(sl < lockSL)
            newSL = lockSL;
         const double trailSL = bid - step;
         if(trailSL > newSL)
            newSL = trailSL;
         if(newSL >= bid)
            continue;
      }
      else
      {
         const double lockSL = open - lock;
         if(sl == 0.0 || sl > lockSL)
            newSL = lockSL;
         const double trailSL = ask + step;
         if(sl == 0.0 || trailSL < newSL)
            newSL = trailSL;
         if(newSL <= ask)
            continue;
      }

      newSL = NSH_NormPrice(newSL);
      if(MathAbs(newSL - sl) < NSH_Point())
         continue;
      if(!g_trade.PositionModify(ticket, newSL, tp))
         NSH_Log("Trail modify failed ticket=" + IntegerToString((long)ticket));
   }
}

//======================================================================
// COMMENT
//======================================================================
void NSH_UpdateComment()
{
   if(!InpShowComment)
      return;

   string rangeTxt = "range: waiting";
   if(g_range_bars > 0 && g_range_high > g_range_low)
      rangeTxt = (g_range_ready ? "range " : "range (forming) ") +
                 DoubleToString(g_range_low, NSH_Digits()) +
                 " / " + DoubleToString(g_range_high, NSH_Digits()) +
                 " (" + IntegerToString(g_range_bars) + " bars)";

   string setupTxt = "setup: none";
   if(g_setup_dir > 0)
      setupTxt = "setup: BUY sweep";
   else if(g_setup_dir < 0)
      setupTxt = "setup: SELL sweep";

   Comment(
      "NY Sweep Hunter v1.00\n",
      "symbol: ", g_symbol, "\n",
      "session: ", (NSH_SessionOK() ? "OPEN" : "closed"),
      "  news: ", (NSH_InNewsBlackout() ? "BLACKOUT" : "ok"), "\n",
      rangeTxt, "\n",
      setupTxt, "\n",
      "positions: ", IntegerToString(NSH_CountPositions()),
      "  basket: ", DoubleToString(NSH_BasketProfit(), 2), "\n",
      "used sides: buy=", (g_used_buy_side ? "yes" : "no"),
      " sell=", (g_used_sell_side ? "yes" : "no")
   );
}

//======================================================================
// EVENTS
//======================================================================
int OnInit()
{
   g_symbol         = _Symbol;
   g_ready          = false;
   g_bar_time       = 0;
   g_cooldown_until = 0;
   g_last_log       = "";
   g_range_ready    = false;
   g_range_day      = 0;
   g_range_high     = 0.0;
   g_range_low      = 0.0;
   g_range_bars     = 0;
   g_used_buy_side  = false;
   g_used_sell_side = false;
   g_used_side_day  = 0;
   g_limit_ticket   = 0;
   g_limit_dir      = 0;
   NSH_ResetSetup();

   if(!NSH_ValidateSymbol())
      return INIT_FAILED;

   if(InpMaxPositions < 1)
   {
      NSH_Log("InpMaxPositions must be >= 1");
      return INIT_FAILED;
   }
   if(InpRR <= 0.0 && InpTPMode == NSH_TP_RR)
   {
      NSH_Log("InpRR must be > 0 when TP mode is RR");
      return INIT_FAILED;
   }

   NSH_PrepareTrade();
   NSH_UpdateRange(true);
   NSH_DrawRange();
   NSH_Log("Ready on " + g_symbol + " TF=" + EnumToString(_Period));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   NSH_ClearDrawings();
   Comment("");
}

void OnTick()
{
   if(!g_ready)
      return;

   NSH_PrepareTrade();
   const bool newBar = NSH_NewBar();
   NSH_UpdateRange(newBar || !g_range_ready);
   NSH_DrawRange();
   NSH_ManageOpen();
   if(newBar)
   {
      NSH_AgeLimit();
      if(NSH_SessionOK() && !NSH_InNewsBlackout())
         NSH_DetectSetup();
   }

   if(!NSH_SessionOK())
   {
      NSH_CancelPendings();
      NSH_UpdateComment();
      return;
   }

   NSH_TryEnter();
   NSH_UpdateComment();
}
