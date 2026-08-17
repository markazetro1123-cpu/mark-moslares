//+------------------------------------------------------------------+
//| EA_CandleRideScalper.mq5                                         |
//| Candle Ride Scalper v1.10                                        |
//|                                                                  |
//| GREEN vs candle open -> BUY only                                 |
//| RED   vs candle open -> SELL only                                |
//| Lock 0.2 -> close + skip next 1 candle                           |
//| Miss lock + color flip -> close and reverse                      |
//| New candle tick 1 -> close leftovers, reset, may enter           |
//| Stack at price (not grid). Lot/entries follow equity. Max 10 lot |
//| No trade on US CPI / NFP / unemployment / rate; enter +10 min    |
//+------------------------------------------------------------------+
#property copyright "Mark Moslares"
#property link      "https://github.com/markazetro1123-cpu/mark-moslares"
#property version   "1.11"
#property description "CandleRide v1.11: market-only, no pending, color follow, lock 0.2"

#include <Trade/Trade.mqh>

//======================================================================
// CONSTANTS
//======================================================================
const int    CRS_FLAT          = 0;
const int    CRS_GREEN         = 1;
const int    CRS_RED           = 2;
const int    CRS_MAX_ENTRIES   = 20;
const int    CRS_SEND_PER_TICK = 3;
const string CRS_PREFIX        = "CRS";

//======================================================================
// INPUTS
//======================================================================
input group "=== Account / Broker ==="
input long     InpMagic              = 260816; // Magic number
input double   InpMinLot             = 0.01;   // Lot at $10
input double   InpMaxLotCap          = 10.0;   // Maximum lot
input int      InpSlippagePoints     = 40;     // Deviation points
input bool     InpAllowBuy           = true;   // Allow BUY on green
input bool     InpAllowSell          = true;   // Allow SELL on red

input group "=== Candle Color ==="
input double   InpOpenBuffer         = 0.0;    // Buffer from candle open (0=auto)

input group "=== Lock / Cycle ==="
input double   InpLockProfit         = 0.0;    // Lock price profit (0=auto gold 0.20)
input int      InpCooldownCandles    = 1;      // Skip this many candles after lock
input double   InpEmergencySL        = 0.0;    // Emergency SL distance (0=auto)

input group "=== US High Impact News ==="
input bool     InpUseNewsFilter      = true;   // Block CPI / NFP / unemployment / rates
input int      InpNewsWaitAfterMin   = 10;     // Minutes after news before next entry
input bool     InpFlattenOnNews      = true;   // Close all when news window starts

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
bool     g_lock_closed_this_bar;
int      g_cooldown_bars;

datetime g_news_until;
string   g_news_name;
datetime g_news_refresh;
bool     g_news_flat_done;

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
   if(vmax > 0.0 && volume > vmax)
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

void CRS_PrepareTrade()
{
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetAsyncMode(false);

   const int modes = (int)SymbolInfoInteger(g_symbol, SYMBOL_FILLING_MODE);
   if((modes & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)
      g_trade.SetTypeFilling(ORDER_FILLING_IOC);
   else if((modes & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK)
      g_trade.SetTypeFilling(ORDER_FILLING_FOK);
   else
      g_trade.SetTypeFillingBySymbol(g_symbol);
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
// LOT / ENTRIES  (locked table B)
//======================================================================
double CRS_Buffer()
{
   if(InpOpenBuffer > 0.0)
      return InpOpenBuffer;
   return 0.0;
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

int CRS_AllowedEntries()
{
   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   int n = 2;
   if(eq >= 25.0)
      n = 3;
   if(eq >= 50.0)
      n = 5;
   if(eq >= 100.0)
      n = 7;
   if(eq >= 200.0)
      n = 10;
   if(eq >= 400.0)
      n = 13;
   if(eq >= 800.0)
      n = 16;
   if(eq >= 1500.0)
      n = 18;
   if(eq >= 3000.0)
      n = 20;
   if(n > CRS_MAX_ENTRIES)
      n = CRS_MAX_ENTRIES;
   return n;
}

double CRS_LotByEquity()
{
   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double lot = InpMinLot;
   if(eq >= 25.0)
      lot = 0.02;
   if(eq >= 50.0)
      lot = 0.03;
   if(eq >= 100.0)
      lot = 0.05;
   if(eq >= 200.0)
      lot = 0.10;
   if(eq >= 400.0)
      lot = 0.20;
   if(eq >= 800.0)
      lot = 0.40;
   if(eq >= 1500.0)
      lot = 0.80;
   if(eq >= 3000.0)
      lot = 1.50;
   if(eq >= 5000.0)
      lot = 3.00;
   if(eq >= 10000.0)
      lot = 6.00;
   if(eq >= 20000.0)
      lot = 10.00;
   if(lot < InpMinLot)
      lot = InpMinLot;
   if(lot > InpMaxLotCap)
      lot = InpMaxLotCap;
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
      else if(dir < 0 && type == POSITION_TYPE_SELL)
         count++;
      else if(dir == 0)
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

bool CRS_CloseTicket(const ulong ticket, const string reason)
{
   if(!g_trade.PositionClose(ticket))
   {
      CRS_Log("Close failed ticket=" + IntegerToString((long)ticket) +
              " err=" + IntegerToString(GetLastError()) + " " + reason);
      return false;
   }
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

int CRS_CloseAll(const string reason)
{
   return CRS_CloseDir(0, reason);
}

int CRS_KillPendings()
{
   int killed = 0;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(OrderGetString(ORDER_SYMBOL) != g_symbol)
         continue;
      if((long)OrderGetInteger(ORDER_MAGIC) != InpMagic)
         continue;
      if(g_trade.OrderDelete(ticket))
         killed++;
   }
   if(killed > 0)
      CRS_Log("Deleted " + IntegerToString(killed) + " pending (market-only EA)");
   return killed;
}

//======================================================================
// NEWS FILTER  (US CPI / NFP / unemployment / interest rate)
//======================================================================
bool CRS_IsWatchedNews(const string name)
{
   const string u = CRS_ToUpper(name);
   if(StringFind(u, "CPI") >= 0)
      return true;
   if(StringFind(u, "CONSUMER PRICE") >= 0)
      return true;
   if(StringFind(u, "NON-FARM") >= 0 || StringFind(u, "NONFARM") >= 0)
      return true;
   if(StringFind(u, "NON FARM") >= 0 || StringFind(u, "NFP") >= 0)
      return true;
   if(StringFind(u, "PAYROLL") >= 0)
      return true;
   if(StringFind(u, "UNEMPLOYMENT") >= 0)
      return true;
   if(StringFind(u, "FEDERAL FUNDS") >= 0)
      return true;
   if(StringFind(u, "INTEREST RATE") >= 0)
      return true;
   if(StringFind(u, "RATE DECISION") >= 0)
      return true;
   if(StringFind(u, "FOMC") >= 0)
      return true;
   return false;
}

int CRS_NyOffsetHours(const datetime gmt)
{
   MqlDateTime dt;
   TimeToStruct(gmt, dt);

   MqlDateTime cursor;
   ZeroMemory(cursor);
   cursor.year = dt.year;
   cursor.mon  = 3;
   cursor.day  = 1;
   datetime mar1 = StructToTime(cursor);
   MqlDateTime m1;
   TimeToStruct(mar1, m1);
   const int marFirstSun = (7 - m1.day_of_week) % 7;
   const datetime dstStart = mar1 + (marFirstSun + 7) * 86400 + 7 * 3600;

   cursor.mon = 11;
   datetime nov1 = StructToTime(cursor);
   MqlDateTime n1;
   TimeToStruct(nov1, n1);
   const int novFirstSun = (7 - n1.day_of_week) % 7;
   const datetime dstEnd = nov1 + novFirstSun * 86400 + 6 * 3600;

   if(gmt >= dstStart && gmt < dstEnd)
      return -4;
   return -5;
}

datetime CRS_FirstFridayNfpGmt(const datetime gmt)
{
   MqlDateTime dt;
   TimeToStruct(gmt, dt);

   MqlDateTime cursor;
   ZeroMemory(cursor);
   cursor.year = dt.year;
   cursor.mon  = dt.mon;
   cursor.day  = 1;
   datetime monthStart = StructToTime(cursor);
   MqlDateTime ms;
   TimeToStruct(monthStart, ms);
   const int add = (5 - ms.day_of_week + 7) % 7;
   const datetime firstFriday = monthStart + add * 86400;
   const int ny = CRS_NyOffsetHours(firstFriday + 12 * 3600);
   return firstFriday + (8 * 3600 + 30 * 60) - ny * 3600;
}

void CRS_RefreshNews()
{
   if(!InpUseNewsFilter)
   {
      g_news_until = 0;
      g_news_name  = "";
      return;
   }

   const datetime now = TimeGMT();
   if(g_news_refresh != 0 && now - g_news_refresh < 30)
      return;
   g_news_refresh = now;

   const int waitSec = MathMax(1, InpNewsWaitAfterMin) * 60;
   datetime until = 0;
   string   name  = "";

   MqlCalendarValue values[];
   const int copied = CalendarValueHistory(values, now - 2 * 3600, now + 6 * 3600, "US", "USD");
   if(copied > 0)
   {
      for(int i = 0; i < copied; ++i)
      {
         MqlCalendarEvent ev;
         if(!CalendarEventById(values[i].event_id, ev))
            continue;
         if(ev.importance < CALENDAR_IMPORTANCE_HIGH)
            continue;
         if(!CRS_IsWatchedNews(ev.name))
            continue;
         const datetime start = values[i].time;
         const datetime end   = start + waitSec;
         if(now >= start && now < end && end > until)
         {
            until = end;
            name  = ev.name;
         }
      }
   }

   if(until == 0)
   {
      const datetime nfp = CRS_FirstFridayNfpGmt(now);
      if(now >= nfp && now < nfp + waitSec)
      {
         until = nfp + waitSec;
         name  = "NFP (first Friday fallback)";
      }
   }

   g_news_until = until;
   g_news_name  = name;
   if(until == 0)
      g_news_flat_done = false;
}

bool CRS_InNewsBlackout()
{
   if(!InpUseNewsFilter)
      return false;
   CRS_RefreshNews();
   return (g_news_until > 0 && TimeGMT() < g_news_until);
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

bool CRS_CanEnter()
{
   if(!g_ready || !CRS_TradeAllowed())
      return false;
   if(g_lock_closed_this_bar)
      return false;
   if(g_cooldown_bars > 0)
      return false;
   if(CRS_InNewsBlackout())
      return false;
   return true;
}

//======================================================================
// ENTRY / LOCK / FLIP
//======================================================================
void CRS_AttachEmergencySL(const ulong ticket, const int dir)
{
   if(ticket == 0 || !PositionSelectByTicket(ticket))
      return;
   const double openP = PositionGetDouble(POSITION_PRICE_OPEN);
   const double dist  = MathMax(CRS_EmergencyDistance(), CRS_StopsDistance() + CRS_Point());
   double sl = 0.0;
   if(dir > 0)
      sl = CRS_NormPrice(openP - dist);
   else
      sl = CRS_NormPrice(openP + dist);
   if(MathAbs(PositionGetDouble(POSITION_SL) - sl) < CRS_Point())
      return;
   g_trade.PositionModify(ticket, sl, 0.0);
}

bool CRS_SendOne(const int dir)
{
   CRS_KillPendings();

   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double entry = (dir > 0 ? ask : bid);
   const ENUM_ORDER_TYPE otype = (dir > 0 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   const double lot = CRS_CalcLot(otype, entry);
   CRS_PrepareTrade();

   // Price 0 = market fill. Never pass ask/bid: that becomes Buy/Sell Limit on RETURN brokers.
   bool sent = false;
   if(dir > 0)
      sent = g_trade.Buy(lot, g_symbol, 0.0, 0.0, 0.0, CRS_PREFIX);
   else
      sent = g_trade.Sell(lot, g_symbol, 0.0, 0.0, 0.0, CRS_PREFIX);

   CRS_KillPendings();

   if(!sent)
   {
      CRS_Log("Market send failed dir=" + IntegerToString(dir) +
              " err=" + IntegerToString(GetLastError()) +
              " ret=" + IntegerToString((int)g_trade.ResultRetcode()));
      return false;
   }

   ulong ticket = 0;
   const ulong resultOrder = g_trade.ResultOrder();
   if(resultOrder != 0 && PositionSelectByTicket(resultOrder))
      ticket = resultOrder;
   else
   {
      for(int i = PositionsTotal() - 1; i >= 0; --i)
      {
         const ulong t = PositionGetTicket(i);
         if(!CRS_IsOurs(t))
            continue;
         const long type = PositionGetInteger(POSITION_TYPE);
         if(dir > 0 && type != POSITION_TYPE_BUY)
            continue;
         if(dir < 0 && type != POSITION_TYPE_SELL)
            continue;
         ticket = t;
         break;
      }
   }
   if(ticket != 0)
      CRS_AttachEmergencySL(ticket, dir);

   g_last_entry_color = (dir > 0 ? CRS_GREEN : CRS_RED);
   CRS_Log((dir > 0 ? "BUY " : "SELL ") +
           "market lot=" + DoubleToString(lot, 2) +
           " price=" + DoubleToString(entry, CRS_Digits()));
   return true;
}

void CRS_FillStack(const int dir)
{
   if(!CRS_CanEnter())
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

void CRS_StartProfitCooldown()
{
   g_lock_closed_this_bar = true;
   int skip = InpCooldownCandles;
   if(skip < 0)
      skip = 0;
   g_cooldown_bars = skip;
}

bool CRS_CheckLockClose()
{
   const double lock = CRS_LockProfit();
   bool any = false;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong ticket = PositionGetTicket(i);
      if(!CRS_IsOurs(ticket))
         continue;
      const long   type  = PositionGetInteger(POSITION_TYPE);
      const double openP = PositionGetDouble(POSITION_PRICE_OPEN);
      const double pp    = CRS_PriceProfit(type, openP);
      if(pp < lock)
         continue;
      if(CRS_CloseTicket(ticket, "lock profit"))
      {
         any = true;
         CRS_Log("Lock close move=" + DoubleToString(pp, CRS_Digits()) +
                 " ticket=" + IntegerToString((long)ticket));
      }
   }

   if(any)
      CRS_StartProfitCooldown();
   return any;
}

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

void CRS_OnNewCandle()
{
   if(CRS_CountDir(0) > 0)
      CRS_CloseAll("new candle reset");

   if(g_lock_closed_this_bar)
      g_lock_closed_this_bar = false;
   else if(g_cooldown_bars > 0)
      g_cooldown_bars--;

   g_color = CRS_FLAT;
   CRS_Log("New candle open=" + DoubleToString(g_open_price, CRS_Digits()) +
           " cooldown=" + IntegerToString(g_cooldown_bars));
}

//======================================================================
// COMMENT
//======================================================================
void CRS_UpdateComment()
{
   if(!InpShowComment)
      return;

   string news = "news: ok";
   if(CRS_InNewsBlackout())
      news = "news: BLOCKED until " + TimeToString(g_news_until, TIME_MINUTES) + " GMT (" + g_news_name + ")";

   string cycle = "cycle: LIVE";
   if(g_lock_closed_this_bar)
      cycle = "cycle: lock-closed this candle";
   else if(g_cooldown_bars > 0)
      cycle = "cycle: cooldown " + IntegerToString(g_cooldown_bars) + " candle";

   Comment(
      "Candle Ride Scalper v1.11\n",
      "symbol: ", g_symbol, "\n",
      "open: ", DoubleToString(g_open_price, CRS_Digits()),
      "  color: ", CRS_ColorName(g_color), "\n",
      "buys: ", IntegerToString(CRS_CountDir(1)),
      "  sells: ", IntegerToString(CRS_CountDir(-1)),
      "  allow: ", IntegerToString(CRS_AllowedEntries()), "\n",
      "lot: ", DoubleToString(CRS_LotByEquity(), 2),
      "  equity: ", DoubleToString(AccountInfoDouble(ACCOUNT_EQUITY), 2), "\n",
      "lock: ", DoubleToString(CRS_LockProfit(), CRS_Digits()),
      "  last entry: ", CRS_ColorName(g_last_entry_color), "\n",
      cycle, "\n",
      news, "\n",
      "basket $: ", DoubleToString(CRS_BasketMoney(), 2)
   );
}

//======================================================================
// EVENTS
//======================================================================
int OnInit()
{
   g_symbol               = _Symbol;
   g_ready                = false;
   g_last_log             = "";
   g_bar_time             = 0;
   g_open_price           = 0.0;
   g_color                = CRS_FLAT;
   g_last_entry_color     = CRS_FLAT;
   g_lock_closed_this_bar = false;
   g_cooldown_bars        = 0;
   g_news_until           = 0;
   g_news_name            = "";
   g_news_refresh         = 0;
   g_news_flat_done       = false;

   if(!CRS_ValidateSymbol())
      return INIT_FAILED;
   if(InpMaxLotCap < InpMinLot)
   {
      CRS_Log("InpMaxLotCap must be >= InpMinLot");
      return INIT_FAILED;
   }
   if(InpNewsWaitAfterMin < 0)
   {
      CRS_Log("InpNewsWaitAfterMin must be >= 0");
      return INIT_FAILED;
   }

   CRS_PrepareTrade();
   CRS_Log("Ready on " + g_symbol + " TF=" + EnumToString(_Period) +
           " lock=" + DoubleToString(CRS_LockProfit(), CRS_Digits()) +
           " maxLot=" + DoubleToString(InpMaxLotCap, 2));
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
   CRS_KillPendings();
   CRS_RefreshNews();

   if(CRS_InNewsBlackout())
   {
      if(InpFlattenOnNews && !g_news_flat_done && CRS_CountDir(0) > 0)
      {
         CRS_CloseAll("news blackout");
         g_news_flat_done = true;
      }
   }

   double openPrice = 0.0;
   if(!CRS_ReadOpen(openPrice))
      return;
   g_open_price = openPrice;

   const datetime barTime = iTime(g_symbol, PERIOD_CURRENT, 0);
   if(barTime > 0 && (g_bar_time == 0 || barTime != g_bar_time))
   {
      const bool firstTick = (g_bar_time != 0);
      g_bar_time = barTime;
      if(firstTick)
         CRS_OnNewCandle();
   }

   if(CRS_CheckLockClose())
   {
      CRS_UpdateComment();
      return;
   }

   g_color = CRS_DetectColor(openPrice);
   if(g_color != CRS_FLAT)
      CRS_OnColor(g_color);

   CRS_UpdateComment();
}
