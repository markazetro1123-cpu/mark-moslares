//+------------------------------------------------------------------+
//| EA_BalochPulse.mq5                                               |
//| Adaptive Tick Pulse EA — XAUUSD + US30 (Tickmill / Deriv)         |
//|                                                                  |
//| SINGLE FILE — copy this one file only.                           |
//|                                                                  |
//| Engines (always-on):                                             |
//|  - Session Guard (NY-London)                                     |
//|  - News/FOMC Guard + hard PM blackouts                           |
//|  - Adaptive Tick Imbalance (no fixed 30 ticks)                   |
//|  - Candle Memory                                                 |
//|  - Risk Manager (lot + entries brain)                            |
//|  - Same-price burst Entry/Add Engine                             |
//|  - Smart Self-Exit Brain                                         |
//|                                                                  |
//| Locked design: no spread filter, no martingale, max 15 entries,  |
//| $30-$50 can intelligently use 2-3 entries, same-price fills.     |
//+------------------------------------------------------------------+
#property copyright "Mark Moslares"
#property link      "https://github.com/markazetro1123-cpu/mark-moslares"
#property version   "1.00"
#property description "BalochPulse: adaptive tick+candle, risk manager, same-price burst, smart exit, news/FOMC"

#include <Trade/Trade.mqh>

//======================================================================
// INPUTS
//======================================================================
input group "=== Core ==="
input long   InpMagic                 = 260726;   // Magic number
input double InpRiskPercent           = 1.5;      // Risk % of equity (lot brain)
input double InpMinLot                = 0.01;     // Minimum lot
input double InpMaxLotCap             = 1.00;     // Maximum lot cap
input int    InpMaxEntriesHard        = 15;       // Hard max entries
input int    InpSlippagePoints        = 30;       // Order deviation (points)
input bool   InpAllowBuy              = true;
input bool   InpAllowSell             = true;

input group "=== Same-Price Burst ==="
input double InpMaxSamePriceSlippage  = 0.0;      // Max distance from 1st fill (0=auto)
input int    InpBurstGapMs            = 250;      // Min ms between burst adds
input int    InpMaxBurstPerPulse      = 3;        // Max adds in one impulse pulse

input group "=== Adaptive Tick Window ==="
input int    InpWindowMinSec          = 2;        // Min adaptive window (sec)
input int    InpWindowMaxSec          = 45;       // Max adaptive window (sec)
input int    InpTickBufferSize        = 800;      // Tick ring buffer size
input double InpImbalanceQuiet        = 0.66;     // Needed imbalance when quiet
input double InpImbalanceBurst        = 0.56;     // Needed imbalance when bursty
input double InpMinNetMovePrice       = 0.0;      // Min net move in window (0=auto)

input group "=== Pullback / Impulse ==="
input int    InpMinImpulseTicks       = 8;        // Min ticks inside adaptive window
input double InpPullbackFrac          = 0.28;     // Pullback depth vs impulse move
input double InpPullbackMaxFrac       = 0.85;     // Cancel if pullback too deep
input int    InpSetupExpireSec        = 25;       // Cancel setup if stale

input group "=== Risk Manager ==="
input bool   InpUseDynamicLot         = true;     // Equity-based lot
input bool   InpUseDynamicEntries     = true;     // Equity/signal-based entries
input bool   InpSameLotPerCycle       = true;     // No martingale (same lot/cycle)
input double InpDdDefensivePct        = 1.2;      // Floating DD% -> DEFENSIVE
input double InpDdLockdownPct         = 2.5;      // Floating DD% -> LOCKDOWN
input int    InpLossStreakDefensive   = 2;        // Losses in a row -> DEFENSIVE
input int    InpLossStreakLockdown    = 4;        // Losses in a row -> LOCKDOWN

input group "=== Smart Exit ==="
input double InpMinProfitToSecure     = 0.0;      // Min $ profit before threat-close (0=auto)
input double InpThreatImbalance       = 0.58;     // Opposite imbalance to threaten
input double InpGivebackFrac          = 0.45;     // Close if give back this fraction of peak
input double InpEmergencyStopDist     = 0.0;      // Emergency SL distance (0=auto)
input int    InpCooldownSec           = 4;        // Seconds after full close

input group "=== Session (NY-London) ==="
input bool   InpUseSessionFilter      = true;     // Trade new entries in session only
input int    InpSessionTZOffsetHrs    = 8;        // Local TZ vs GMT (PH=8)
input int    InpSessionStartHour      = 20;       // Session start hour (local)
input int    InpSessionStartMinute    = 0;
input int    InpSessionEndHour        = 1;        // Session end hour (local)
input int    InpSessionEndMinute      = 0;

input group "=== News / FOMC Guard ==="
input bool   InpUseHardBlackouts      = true;     // 8:30-8:40 & 9:30-9:40 PM local
input bool   InpUseCalendarFilter     = true;     // MT5 economic calendar
input int    InpNewsBufferMin         = 8;        // Minutes around high-impact USD
input int    InpFomcBlockMin          = 45;       // Minutes around FOMC events
input bool   InpCloseOnNewsThreat     = true;     // Allow exit brain during news block

input group "=== Runtime ==="
input bool   InpStrictSymbolCheck     = true;     // Only XAUUSD / US30 family
input int    InpMemoryTrades          = 12;       // Recent trades remembered
input bool   InpPrintLogs             = true;     // Print key decisions

//======================================================================
// ENUMS / STRUCTS
//======================================================================
enum ENUM_BP_STATE
{
   BP_IDLE = 0,
   BP_BIAS_DETECT,
   BP_IMPULSE_CONFIRM,
   BP_WAIT_PULLBACK,
   BP_ENTER_BURST,
   BP_MANAGE,
   BP_COOLDOWN
};

enum ENUM_BP_MODE
{
   BP_MODE_AGGRESSIVE = 0,
   BP_MODE_NORMAL,
   BP_MODE_DEFENSIVE,
   BP_MODE_LOCKDOWN
};

enum ENUM_BP_BIAS
{
   BP_BIAS_NONE = 0,
   BP_BIAS_BUY  = 1,
   BP_BIAS_SELL = -1
};

struct TickSample
{
   datetime time_msc; // ms as datetime-like long store
   long     time_ms;
   double   bid;
   double   ask;
   int      dir; // +1 up, -1 down, 0 flat
};

struct TradeMemory
{
   bool   used;
   bool   win;
   double pnl;
   datetime time;
};

//======================================================================
// GLOBALS
//======================================================================
CTrade trade;

string   g_symbol;
bool     g_symbol_ok = false;
bool     g_is_gold   = false;
bool     g_is_us30   = false;

TickSample g_ticks[];
int        g_tick_cap = 0;
int        g_tick_head = 0;
int        g_tick_count = 0;
double     g_last_mid = 0.0;

ENUM_BP_STATE g_state = BP_IDLE;
ENUM_BP_BIAS  g_bias  = BP_BIAS_NONE;
ENUM_BP_MODE  g_mode  = BP_MODE_NORMAL;

datetime g_setup_time = 0;
double   g_impulse_move = 0.0;
double   g_impulse_extreme = 0.0;
double   g_pullback_extreme = 0.0;
bool     g_pullback_seen = false;

double   g_first_fill_price = 0.0;
double   g_cycle_lot = 0.0;
int      g_burst_count = 0;
ulong    g_last_burst_ms = 0;
datetime g_cooldown_until = 0;

double   g_peak_profit = 0.0;
int      g_loss_streak = 0;
int      g_win_streak  = 0;

TradeMemory g_memory[];
int         g_mem_pos = 0;

datetime g_last_news_check = 0;
bool     g_news_block = false;
string   g_news_reason = "";

string   g_last_log = "";

//======================================================================
// UTILS
//======================================================================
void BP_Log(const string msg)
{
   if(!InpPrintLogs) return;
   if(msg == g_last_log) return;
   g_last_log = msg;
   Print("[BalochPulse] ", msg);
}

double BP_Point()
{
   const double p = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   return (p > 0.0 ? p : _Point);
}

int BP_Digits()
{
   return (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
}

double BP_NormPrice(const double price)
{
   return NormalizeDouble(price, BP_Digits());
}

double BP_NormVol(double vol)
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

bool BP_SelectFilling(ENUM_ORDER_TYPE_FILLING &filling)
{
   const int modes = (int)SymbolInfoInteger(g_symbol, SYMBOL_FILLING_MODE);
   if((modes & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) { filling = ORDER_FILLING_IOC; return true; }
   if((modes & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) { filling = ORDER_FILLING_FOK; return true; }
   filling = ORDER_FILLING_RETURN;
   return true;
}

double BP_StopsDist()
{
   const int stops  = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const int freeze = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return MathMax(stops, freeze) * BP_Point();
}

bool BP_TradeOk()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;
   if(SymbolInfoInteger(g_symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED) return false;
   return true;
}

double BP_Mid()
{
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0) return 0.0;
   return (bid + ask) * 0.5;
}

double BP_AutoPriceUnit()
{
   // Reasonable default movement unit per symbol family
   if(g_is_us30) return MathMax(0.5, 50.0 * BP_Point());
   return MathMax(0.05, 50.0 * BP_Point());
}

double BP_SamePriceBand()
{
   if(InpMaxSamePriceSlippage > 0.0) return InpMaxSamePriceSlippage;
   if(g_is_us30) return MathMax(1.5, 120.0 * BP_Point());
   return MathMax(0.15, 120.0 * BP_Point());
}

double BP_MinNetMove()
{
   if(InpMinNetMovePrice > 0.0) return InpMinNetMovePrice;
   return BP_AutoPriceUnit() * 0.35;
}

double BP_EmergencyStop()
{
   if(InpEmergencyStopDist > 0.0) return InpEmergencyStopDist;
   if(g_is_us30) return MathMax(25.0, 800.0 * BP_Point());
   return MathMax(3.0, 800.0 * BP_Point());
}

double BP_MinSecureMoney()
{
   if(InpMinProfitToSecure > 0.0) return InpMinProfitToSecure;
   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   // Tiny accounts: secure even small green
   if(eq < 50.0) return MathMax(0.08, eq * 0.002);
   if(eq < 200.0) return MathMax(0.20, eq * 0.0015);
   return MathMax(0.50, eq * 0.001);
}

ulong BP_NowMs()
{
   return (ulong)GetTickCount64();
}

int BP_LocalMinuteOfDay()
{
   const datetime tz = TimeGMT() + InpSessionTZOffsetHrs * 3600;
   MqlDateTime dt;
   TimeToStruct(tz, dt);
   return dt.hour * 60 + dt.min;
}

bool BP_InMinuteWindow(const int now, const int startMin, const int endMin)
{
   // [start, end)
   if(startMin == endMin) return false;
   if(startMin < endMin) return (now >= startMin && now < endMin);
   return (now >= startMin || now < endMin);
}

string BP_ModeName(const ENUM_BP_MODE m)
{
   if(m == BP_MODE_AGGRESSIVE) return "AGGRESSIVE";
   if(m == BP_MODE_DEFENSIVE)  return "DEFENSIVE";
   if(m == BP_MODE_LOCKDOWN)   return "LOCKDOWN";
   return "NORMAL";
}

string BP_StateName(const ENUM_BP_STATE s)
{
   switch(s)
   {
      case BP_BIAS_DETECT:      return "BIAS_DETECT";
      case BP_IMPULSE_CONFIRM:  return "IMPULSE_CONFIRM";
      case BP_WAIT_PULLBACK:    return "WAIT_PULLBACK";
      case BP_ENTER_BURST:      return "ENTER_BURST";
      case BP_MANAGE:           return "MANAGE";
      case BP_COOLDOWN:         return "COOLDOWN";
      default:                  return "IDLE";
   }
}

//======================================================================
// SYMBOL FAMILY
//======================================================================
string BP_Upper(string s)
{
   StringToUpper(s);
   return s;
}

bool BP_IsGoldSymbol(const string s)
{
   const string u = BP_Upper(s);
   if(StringFind(u, "XAUUSD") >= 0) return true;
   if(StringFind(u, "GOLD") >= 0 && StringFind(u, "GOLDF") < 0) return true;
   return false;
}

bool BP_IsUS30Symbol(const string s)
{
   const string u = BP_Upper(s);
   if(StringFind(u, "US30") >= 0) return true;
   if(StringFind(u, "DJ30") >= 0) return true;
   if(StringFind(u, "DJIA") >= 0) return true;
   if(StringFind(u, "WALLSTREET30") >= 0) return true;
   if(StringFind(u, "WST30") >= 0) return true;
   if(StringFind(u, "DOWJONES") >= 0) return true;
   if(u == "USTEC" ) return false;
   return false;
}

bool BP_ValidateSymbol()
{
   g_symbol = _Symbol;
   g_is_gold = BP_IsGoldSymbol(g_symbol);
   g_is_us30 = BP_IsUS30Symbol(g_symbol);
   g_symbol_ok = (g_is_gold || g_is_us30);

   if(!g_symbol_ok && InpStrictSymbolCheck)
   {
      BP_Log("Unsupported symbol: " + g_symbol + " (use XAUUSD or US30 family)");
      return false;
   }
   if(!g_symbol_ok)
   {
      BP_Log("Warning: non XAU/US30 symbol, running in generic mode: " + g_symbol);
      g_symbol_ok = true;
   }
   return true;
}

//======================================================================
// SESSION + NEWS GUARDS
//======================================================================
bool BP_InNyLondonSession()
{
   if(!InpUseSessionFilter) return true;
   const int now = BP_LocalMinuteOfDay();
   const int a = InpSessionStartHour * 60 + InpSessionStartMinute;
   const int b = InpSessionEndHour * 60 + InpSessionEndMinute;
   return BP_InMinuteWindow(now, a, b);
}

bool BP_InHardBlackout(string &reason)
{
   if(!InpUseHardBlackouts) return false;
   const int now = BP_LocalMinuteOfDay();
   // 20:30-20:40 and 21:30-21:40 local
   if(BP_InMinuteWindow(now, 20 * 60 + 30, 20 * 60 + 40))
   {
      reason = "Hard blackout 20:30-20:40";
      return true;
   }
   if(BP_InMinuteWindow(now, 21 * 60 + 30, 21 * 60 + 40))
   {
      reason = "Hard blackout 21:30-21:40";
      return true;
   }
   return false;
}

bool BP_IsFomcText(const string text)
{
   string u = text;
   StringToUpper(u);
   if(StringFind(u, "FOMC") >= 0) return true;
   if(StringFind(u, "FEDERAL FUNDS") >= 0) return true;
   if(StringFind(u, "FED RATE") >= 0) return true;
   if(StringFind(u, "INTEREST RATE DECISION") >= 0) return true;
   if(StringFind(u, "FEDERAL OPEN MARKET") >= 0) return true;
   if(StringFind(u, "MONETARY POLICY STATEMENT") >= 0) return true;
   return false;
}

bool BP_CalendarBlocked(string &reason)
{
   if(!InpUseCalendarFilter) return false;

   // Refresh at most once per 15s
   if(TimeCurrent() - g_last_news_check < 15 && g_last_news_check > 0)
   {
      reason = g_news_reason;
      return g_news_block;
   }
   g_last_news_check = TimeCurrent();
   g_news_block = false;
   g_news_reason = "";

   const datetime now = TimeTradeServer();
   const datetime from = now - InpFomcBlockMin * 60;
   const datetime to   = now + InpFomcBlockMin * 60;

   MqlCalendarValue values[];
   // USD country code in MT5 calendar is usually "US"
   int n = CalendarValueHistory(values, from, to, "US", NULL);
   if(n <= 0)
   {
      // Some builds want empty country filter then manual check
      n = CalendarValueHistory(values, from, to, NULL, NULL);
   }
   if(n <= 0) return false;

   for(int i = 0; i < n; i++)
   {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev)) continue;

      MqlCalendarCountry co;
      string country = "";
      if(CalendarCountryById(ev.country_id, co))
         country = co.code;

      // Focus USD / US
      if(country != "" && country != "US")
         continue;

      const bool isFomc = BP_IsFomcText(ev.name);
      const bool highImpact = (ev.importance == CALENDAR_IMPORTANCE_HIGH);

      if(!isFomc && !highImpact)
         continue;

      datetime eventTime = values[i].time;
      int blockMin = isFomc ? InpFomcBlockMin : InpNewsBufferMin;
      if(now >= eventTime - blockMin * 60 && now <= eventTime + blockMin * 60)
      {
         g_news_block = true;
         g_news_reason = (isFomc ? "FOMC block: " : "High-impact USD: ") + ev.name;
         reason = g_news_reason;
         return true;
      }
   }
   return false;
}

bool BP_NewsBlocked(string &reason)
{
   if(BP_InHardBlackout(reason)) return true;
   if(BP_CalendarBlocked(reason)) return true;
   return false;
}

bool BP_CanOpenNewEntries(string &reason)
{
   if(!BP_InNyLondonSession())
   {
      reason = "Outside NY-London session";
      return false;
   }
   if(BP_NewsBlocked(reason))
      return false;
   return true;
}

//======================================================================
// TICK BUFFER + ADAPTIVE SIGNAL
//======================================================================
void BP_TickInit()
{
   g_tick_cap = MathMax(100, InpTickBufferSize);
   ArrayResize(g_ticks, g_tick_cap);
   g_tick_head = 0;
   g_tick_count = 0;
   g_last_mid = 0.0;
}

void BP_PushTick()
{
   MqlTick t;
   if(!SymbolInfoTick(g_symbol, t)) return;
   const double mid = (t.bid + t.ask) * 0.5;
   if(mid <= 0.0) return;

   int dir = 0;
   if(g_last_mid > 0.0)
   {
      if(mid > g_last_mid) dir = 1;
      else if(mid < g_last_mid) dir = -1;
   }
   g_last_mid = mid;

   g_ticks[g_tick_head].time_ms = (long)t.time_msc;
   g_ticks[g_tick_head].time_msc = (datetime)(t.time_msc / 1000);
   g_ticks[g_tick_head].bid = t.bid;
   g_ticks[g_tick_head].ask = t.ask;
   g_ticks[g_tick_head].dir = dir;

   g_tick_head = (g_tick_head + 1) % g_tick_cap;
   if(g_tick_count < g_tick_cap) g_tick_count++;
}

bool BP_GetTick(const int ageFromNewest, TickSample &out)
{
   if(ageFromNewest < 0 || ageFromNewest >= g_tick_count) return false;
   int idx = g_tick_head - 1 - ageFromNewest;
   while(idx < 0) idx += g_tick_cap;
   out = g_ticks[idx];
   return true;
}

struct AdaptiveSignal
{
   bool   valid;
   double upBias;
   double downBias;
   double netMove;
   double ticksPerSec;
   double movePerSec;
   int    ticksUsed;
   int    windowSec;
   double threshold;
   ENUM_BP_BIAS bias;
};

double BP_ClampD(const double v, const double lo, const double hi)
{
   return MathMax(lo, MathMin(hi, v));
}

int BP_ClampI(const int v, const int lo, const int hi)
{
   return (int)MathMax(lo, MathMin(hi, v));
}

AdaptiveSignal BP_BuildSignal()
{
   AdaptiveSignal sig;
   ZeroMemory(sig);
   sig.bias = BP_BIAS_NONE;

   if(g_tick_count < InpMinImpulseTicks)
      return sig;

   // Quick speed estimate from last ~3 seconds
   TickSample newest, older;
   if(!BP_GetTick(0, newest)) return sig;

   long newest_ms = newest.time_ms;
   int fastTicks = 0;
   double fastFirst = newest.bid;
   for(int i = 0; i < g_tick_count; i++)
   {
      TickSample ts;
      if(!BP_GetTick(i, ts)) break;
      if(newest_ms - ts.time_ms > 3000) break;
      fastTicks++;
      fastFirst = (ts.bid + ts.ask) * 0.5;
   }
   const double newestMid = (newest.bid + newest.ask) * 0.5;
   double tps = (fastTicks > 1 ? fastTicks / 3.0 : 1.0);
   double mps = MathAbs(newestMid - fastFirst) / 3.0;
   sig.ticksPerSec = tps;
   sig.movePerSec  = mps;

   // Adaptive window seconds from speed
   // Fast ticks => shorter window; slow => longer
   double target = 16.0;
   if(tps >= 8.0) target = 4.0;
   else if(tps >= 4.0) target = 7.0;
   else if(tps >= 2.0) target = 12.0;
   else if(tps >= 1.0) target = 20.0;
   else target = 35.0;

   // If price is moving hard, shorten a bit more
   const double unit = BP_AutoPriceUnit();
   if(mps > unit * 0.8) target *= 0.7;
   if(mps < unit * 0.15) target *= 1.25;

   int winSec = BP_ClampI((int)MathRound(target), InpWindowMinSec, InpWindowMaxSec);
   sig.windowSec = winSec;

   long winMs = (long)winSec * 1000;
   int up = 0, down = 0, used = 0;
   double firstMid = newestMid;
   double lastMid = newestMid;

   for(int i = 0; i < g_tick_count; i++)
   {
      TickSample ts;
      if(!BP_GetTick(i, ts)) break;
      if(newest_ms - ts.time_ms > winMs) break;
      used++;
      if(ts.dir > 0) up++;
      else if(ts.dir < 0) down++;
      firstMid = (ts.bid + ts.ask) * 0.5;
   }

   if(used < InpMinImpulseTicks)
      return sig;

   const int dirTicks = up + down;
   if(dirTicks <= 0) return sig;

   sig.ticksUsed = used;
   sig.upBias = (double)up / (double)dirTicks;
   sig.downBias = (double)down / (double)dirTicks;
   sig.netMove = newestMid - firstMid;

   // Adaptive threshold
   double thr = InpImbalanceQuiet;
   if(tps >= 5.0) thr = InpImbalanceBurst;
   else if(tps >= 2.5) thr = 0.5 * (InpImbalanceBurst + InpImbalanceQuiet);
   sig.threshold = thr;

   const double minMove = BP_MinNetMove();
   if(sig.upBias >= thr && sig.netMove >= minMove)
      sig.bias = BP_BIAS_BUY;
   else if(sig.downBias >= thr && sig.netMove <= -minMove)
      sig.bias = BP_BIAS_SELL;

   sig.valid = true;
   return sig;
}

//======================================================================
// CANDLE MEMORY
//======================================================================
bool BP_CandleAgrees(const ENUM_BP_BIAS bias)
{
   if(bias == BP_BIAS_NONE) return false;

   double o[], c[], h[], l[];
   ArraySetAsSeries(o, true);
   ArraySetAsSeries(c, true);
   ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true);

   if(CopyOpen(g_symbol, PERIOD_CURRENT, 0, 3, o) < 3) return false;
   if(CopyClose(g_symbol, PERIOD_CURRENT, 0, 3, c) < 3) return false;
   if(CopyHigh(g_symbol, PERIOD_CURRENT, 0, 3, h) < 3) return false;
   if(CopyLow(g_symbol, PERIOD_CURRENT, 0, 3, l) < 3) return false;

   const double body0 = c[0] - o[0];
   const double body1 = c[1] - o[1];
   const double range1 = MathMax(BP_Point(), h[1] - l[1]);
   const double closePos1 = (c[1] - l[1]) / range1;

   if(bias == BP_BIAS_BUY)
   {
      // Prefer green pressure / not heavy sell rejection
      if(body1 < -range1 * 0.65 && closePos1 < 0.25) return false;
      if(body0 < -MathAbs(body1) * 1.2 && body0 < 0) return false;
      return (body1 >= 0.0 || body0 >= 0.0 || closePos1 >= 0.55);
   }

   // SELL
   if(body1 > range1 * 0.65 && closePos1 > 0.75) return false;
   if(body0 > MathAbs(body1) * 1.2 && body0 > 0) return false;
   return (body1 <= 0.0 || body0 <= 0.0 || closePos1 <= 0.45);
}

bool BP_CandleThreat(const ENUM_BP_BIAS openBias)
{
   // Threat against open positions
   if(openBias == BP_BIAS_NONE) return false;
   double o[], c[], h[], l[];
   ArraySetAsSeries(o, true);
   ArraySetAsSeries(c, true);
   ArraySetAsSeries(h, true);
   ArraySetAsSeries(l, true);
   if(CopyOpen(g_symbol, PERIOD_CURRENT, 0, 2, o) < 2) return false;
   if(CopyClose(g_symbol, PERIOD_CURRENT, 0, 2, c) < 2) return false;
   if(CopyHigh(g_symbol, PERIOD_CURRENT, 0, 2, h) < 2) return false;
   if(CopyLow(g_symbol, PERIOD_CURRENT, 0, 2, l) < 2) return false;

   const double range = MathMax(BP_Point(), h[0] - l[0]);
   const double body = c[0] - o[0];

   if(openBias == BP_BIAS_BUY)
      return (body < -range * 0.35);
   return (body > range * 0.35);
}

//======================================================================
// POSITION HELPERS
//======================================================================
int BP_CountPositions()
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      n++;
   }
   return n;
}

ENUM_BP_BIAS BP_OpenBias()
{
   ENUM_BP_BIAS b = BP_BIAS_NONE;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      const long type = PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_BUY)
      {
         if(b == BP_BIAS_SELL) return BP_BIAS_NONE; // mixed unexpected
         b = BP_BIAS_BUY;
      }
      else if(type == POSITION_TYPE_SELL)
      {
         if(b == BP_BIAS_BUY) return BP_BIAS_NONE;
         b = BP_BIAS_SELL;
      }
   }
   return b;
}

double BP_FloatingProfit()
{
   double pnl = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      pnl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return pnl;
}

double BP_FirstOpenPrice()
{
   datetime oldest = 0;
   double price = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      const datetime t = (datetime)PositionGetInteger(POSITION_TIME);
      if(oldest == 0 || t < oldest)
      {
         oldest = t;
         price = PositionGetDouble(POSITION_PRICE_OPEN);
      }
   }
   return price;
}

bool BP_CloseAll(const string why)
{
   bool ok = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(!trade.PositionClose(ticket))
      {
         ok = false;
         BP_Log("Close fail #" + IntegerToString((int)ticket) + " ret=" + IntegerToString(trade.ResultRetcode()));
      }
   }
   if(ok) BP_Log("Closed all: " + why);
   return ok;
}

void BP_EnsureEmergencySL()
{
   const double dist = BP_EmergencyStop();
   const double minDist = MathMax(dist, BP_StopsDist() + 2.0 * BP_Point());

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;

      const double sl = PositionGetDouble(POSITION_SL);
      if(sl > 0.0) continue;

      const long type = PositionGetInteger(POSITION_TYPE);
      const double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double newSL = 0.0;
      if(type == POSITION_TYPE_BUY)
         newSL = BP_NormPrice(open - minDist);
      else
         newSL = BP_NormPrice(open + minDist);

      trade.PositionModify(ticket, newSL, PositionGetDouble(POSITION_TP));
   }
}

//======================================================================
// MEMORY + RISK MANAGER
//======================================================================
void BP_MemoryInit()
{
   ArrayResize(g_memory, MathMax(4, InpMemoryTrades));
   for(int i = 0; i < ArraySize(g_memory); i++)
   {
      g_memory[i].used = false;
      g_memory[i].win = false;
      g_memory[i].pnl = 0.0;
      g_memory[i].time = 0;
   }
   g_mem_pos = 0;
}

void BP_MemoryAdd(const double pnl)
{
   g_memory[g_mem_pos].used = true;
   g_memory[g_mem_pos].pnl = pnl;
   g_memory[g_mem_pos].win = (pnl > 0.0);
   g_memory[g_mem_pos].time = TimeCurrent();
   g_mem_pos = (g_mem_pos + 1) % ArraySize(g_memory);

   if(pnl > 0.0)
   {
      g_win_streak++;
      g_loss_streak = 0;
   }
   else if(pnl < 0.0)
   {
      g_loss_streak++;
      g_win_streak = 0;
   }
}

double BP_RecentWinRate(int &samples)
{
   int wins = 0;
   samples = 0;
   for(int i = 0; i < ArraySize(g_memory); i++)
   {
      if(!g_memory[i].used) continue;
      samples++;
      if(g_memory[i].win) wins++;
   }
   if(samples <= 0) return 0.5;
   return (double)wins / (double)samples;
}

double BP_LossPerLot(const double dist)
{
   if(dist <= 0.0) return 0.0;
   const double ts = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
   const double tv = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);
   if(ts <= 0.0 || tv <= 0.0) return 0.0;
   return (dist / ts) * tv;
}

double BP_MaxLotMargin(const ENUM_ORDER_TYPE type, const double price)
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
   return BP_NormVol((free * 0.65) / m1);
}

int BP_BaseEntriesByEquity(const double eq)
{
   // Intelligent floor: $30-$50 can already do 2-3
   if(eq < 20.0)  return 1;
   if(eq < 30.0)  return 2;
   if(eq < 80.0)  return 3;
   if(eq < 150.0) return 4;
   if(eq < 300.0) return 6;
   if(eq < 600.0) return 8;
   if(eq < 1200.0) return 11;
   if(eq < 2500.0) return 13;
   return InpMaxEntriesHard;
}

ENUM_BP_MODE BP_RiskMode(const AdaptiveSignal &sig, const double floatingPnl)
{
   const double eq = MathMax(1.0, AccountInfoDouble(ACCOUNT_EQUITY));
   const double ddPct = (floatingPnl < 0.0 ? (-floatingPnl / eq) * 100.0 : 0.0);

   if(ddPct >= InpDdLockdownPct || g_loss_streak >= InpLossStreakLockdown)
      return BP_MODE_LOCKDOWN;

   if(ddPct >= InpDdDefensivePct || g_loss_streak >= InpLossStreakDefensive)
      return BP_MODE_DEFENSIVE;

   int samples = 0;
   const double wr = BP_RecentWinRate(samples);
   const bool strong = (sig.valid && sig.bias != BP_BIAS_NONE &&
                        MathMax(sig.upBias, sig.downBias) >= sig.threshold + 0.04 &&
                        MathAbs(sig.netMove) >= BP_MinNetMove() * 1.25);

   if(strong && ddPct < InpDdDefensivePct * 0.35 && (samples < 3 || wr >= 0.45) && g_win_streak >= 1)
      return BP_MODE_AGGRESSIVE;

   if(strong && ddPct < InpDdDefensivePct * 0.5 && g_loss_streak == 0)
      return BP_MODE_AGGRESSIVE;

   return BP_MODE_NORMAL;
}

int BP_AllowedEntries(const ENUM_BP_MODE mode, const AdaptiveSignal &sig)
{
   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   int base = BP_BaseEntriesByEquity(eq);
   base = BP_ClampI(base, 1, InpMaxEntriesHard);

   if(!InpUseDynamicEntries)
      return BP_ClampI(base, 1, InpMaxEntriesHard);

   if(mode == BP_MODE_LOCKDOWN) return 0;
   if(mode == BP_MODE_DEFENSIVE) return MathMax(1, base / 2);

   // Signal quality can reduce/increase
   int allowed = base;
   if(sig.valid)
   {
      const double imb = MathMax(sig.upBias, sig.downBias);
      if(imb < sig.threshold + 0.02) allowed = MathMax(1, allowed - 1);
      if(imb >= sig.threshold + 0.08 && mode == BP_MODE_AGGRESSIVE)
         allowed = MathMin(InpMaxEntriesHard, allowed + 1);
   }

   // Small capital intelligent floor already in base; keep burst sensible
   if(eq < 80.0 && mode == BP_MODE_AGGRESSIVE)
      allowed = MathMax(allowed, 2);

   return BP_ClampI(allowed, 0, InpMaxEntriesHard);
}

double BP_CalcLot(const ENUM_ORDER_TYPE type, const double price, const ENUM_BP_MODE mode)
{
   if(!InpUseDynamicLot)
      return BP_NormVol(InpMinLot);

   if(InpSameLotPerCycle && g_cycle_lot > 0.0 && BP_CountPositions() > 0)
      return BP_NormVol(g_cycle_lot);

   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   const double dist = BP_EmergencyStop();
   const double lossPerLot = BP_LossPerLot(dist);

   double lot = InpMinLot;
   if(lossPerLot > 0.0)
      lot = (eq * InpRiskPercent / 100.0) / lossPerLot;

   // Equity step growth feel (not martingale)
   if(eq >= 50.0)  lot = MathMax(lot, InpMinLot * 1.0);
   if(eq >= 100.0) lot = MathMax(lot, InpMinLot * 2.0);
   if(eq >= 250.0) lot = MathMax(lot, InpMinLot * 3.0);
   if(eq >= 500.0) lot = MathMax(lot, InpMinLot * 5.0);
   if(eq >= 1000.0) lot = MathMax(lot, InpMinLot * 8.0);
   if(eq >= 2000.0) lot = MathMax(lot, InpMinLot * 12.0);

   if(mode == BP_MODE_AGGRESSIVE) lot *= 1.15;
   if(mode == BP_MODE_DEFENSIVE)  lot *= 0.70;
   if(mode == BP_MODE_LOCKDOWN)   lot = InpMinLot;

   lot = MathMin(lot, BP_MaxLotMargin(type, price));
   lot = BP_NormVol(lot);
   return lot;
}

bool BP_RiskAllowsAdd(const ENUM_BP_MODE mode, const int openN, const int allowed, string &reason)
{
   if(mode == BP_MODE_LOCKDOWN)
   {
      reason = "Risk LOCKDOWN";
      return false;
   }
   if(allowed <= 0)
   {
      reason = "No entries allowed";
      return false;
   }
   if(openN >= allowed)
   {
      reason = "At allowed entries";
      return false;
   }
   if(openN >= InpMaxEntriesHard)
   {
      reason = "Hard max 15";
      return false;
   }
   if(mode == BP_MODE_DEFENSIVE && openN >= 1)
   {
      reason = "DEFENSIVE: no add";
      return false;
   }
   return true;
}

//======================================================================
// ENTRY ENGINE (SAME PRICE BURST)
//======================================================================
bool BP_PriceInSameBand(const double refPrice, const ENUM_ORDER_TYPE type)
{
   if(refPrice <= 0.0) return true;
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double px = (type == ORDER_TYPE_BUY ? ask : bid);
   return (MathAbs(px - refPrice) <= BP_SamePriceBand());
}

bool BP_OpenMarket(const ENUM_BP_BIAS bias, const double lot)
{
   if(bias == BP_BIAS_BUY && !InpAllowBuy) return false;
   if(bias == BP_BIAS_SELL && !InpAllowSell) return false;
   if(!BP_TradeOk()) return false;

   ENUM_ORDER_TYPE_FILLING fill;
   BP_SelectFilling(fill);
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFilling(fill);

   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double dist = MathMax(BP_EmergencyStop(), BP_StopsDist() + 2.0 * BP_Point());

   bool ok = false;
   if(bias == BP_BIAS_BUY)
   {
      const double sl = BP_NormPrice(ask - dist);
      ok = trade.Buy(lot, g_symbol, ask, sl, 0.0, "BP-BUY");
   }
   else
   {
      const double sl = BP_NormPrice(bid + dist);
      ok = trade.Sell(lot, g_symbol, bid, sl, 0.0, "BP-SELL");
   }

   if(!ok)
      BP_Log("Entry fail ret=" + IntegerToString(trade.ResultRetcode()) + " " + trade.ResultRetcodeDescription());
   return ok;
}

bool BP_TryBurstEntry(const AdaptiveSignal &sig)
{
   string reason;
   if(!BP_CanOpenNewEntries(reason))
   {
      BP_Log("No entry: " + reason);
      return false;
   }

   const int openN = BP_CountPositions();
   const ENUM_BP_MODE mode = BP_RiskMode(sig, BP_FloatingProfit());
   g_mode = mode;
   const int allowed = BP_AllowedEntries(mode, sig);

   if(!BP_RiskAllowsAdd(mode, openN, allowed, reason))
   {
      BP_Log("Risk block: " + reason + " mode=" + BP_ModeName(mode));
      return false;
   }

   ENUM_BP_BIAS bias = g_bias;
   if(bias == BP_BIAS_NONE) bias = sig.bias;
   if(bias == BP_BIAS_NONE) return false;

   // Keep one-way only
   const ENUM_BP_BIAS openBias = BP_OpenBias();
   if(openBias != BP_BIAS_NONE && openBias != bias)
   {
      BP_Log("Skip: opposite to open basket");
      return false;
   }

   const ENUM_ORDER_TYPE otype = (bias == BP_BIAS_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   const double price = (bias == BP_BIAS_BUY ? SymbolInfoDouble(g_symbol, SYMBOL_ASK)
                                             : SymbolInfoDouble(g_symbol, SYMBOL_BID));

   double ref = g_first_fill_price;
   if(ref <= 0.0 && openN > 0)
      ref = BP_FirstOpenPrice();

   if(!BP_PriceInSameBand(ref, otype))
   {
      BP_Log("Skip add: outside same-price band");
      return false;
   }

   // Burst pacing
   const ulong nowMs = BP_NowMs();
   if(g_last_burst_ms > 0 && (nowMs - g_last_burst_ms) < (ulong)InpBurstGapMs)
      return false;
   if(g_burst_count >= InpMaxBurstPerPulse && openN > 0)
      return false;

   double lot = BP_CalcLot(otype, price, mode);
   if(lot <= 0.0) return false;

   if(BP_OpenMarket(bias, lot))
   {
      if(g_cycle_lot <= 0.0) g_cycle_lot = lot;
      if(g_first_fill_price <= 0.0)
         g_first_fill_price = (bias == BP_BIAS_BUY ? SymbolInfoDouble(g_symbol, SYMBOL_ASK)
                                                   : SymbolInfoDouble(g_symbol, SYMBOL_BID));
      g_burst_count++;
      g_last_burst_ms = nowMs;
      g_bias = bias;
      g_state = BP_MANAGE;
      BP_Log("ENTER " + (bias == BP_BIAS_BUY ? "BUY" : "SELL") +
             " lot=" + DoubleToString(lot, 2) +
             " mode=" + BP_ModeName(mode) +
             " allowed=" + IntegerToString(allowed) +
             " open=" + IntegerToString(openN + 1));
      return true;
   }
   return false;
}

//======================================================================
// EXIT BRAIN
//======================================================================
bool BP_ShouldThreatClose(const ENUM_BP_BIAS openBias, const AdaptiveSignal &sig, const double pnl)
{
   if(openBias == BP_BIAS_NONE) return false;

   const double minSecure = BP_MinSecureMoney();
   if(pnl > g_peak_profit) g_peak_profit = pnl;

   // Opposite imbalance threat
   bool oppositeImb = false;
   if(sig.valid)
   {
      if(openBias == BP_BIAS_BUY)
         oppositeImb = (sig.downBias >= InpThreatImbalance && sig.netMove < 0.0);
      else
         oppositeImb = (sig.upBias >= InpThreatImbalance && sig.netMove > 0.0);
   }

   const bool candleThreat = BP_CandleThreat(openBias);
   const bool hadProfit = (g_peak_profit >= minSecure);
   const bool giveback = (hadProfit && pnl <= g_peak_profit * (1.0 - InpGivebackFrac));
   const bool flipToRedRisk = (hadProfit && pnl < minSecure * 0.35 && (oppositeImb || candleThreat));

   if(hadProfit && oppositeImb && candleThreat) return true;
   if(hadProfit && giveback && (oppositeImb || candleThreat)) return true;
   if(flipToRedRisk) return true;

   // If never green and strong opposite with lockdown, cut sooner
   if(g_mode == BP_MODE_LOCKDOWN && pnl < 0.0 && oppositeImb) return true;

   return false;
}

void BP_OnDealClosedMemory()
{
   // Approximate: when flat after having managed, memory is updated in manage transition
}

//======================================================================
// STATE MACHINE
//======================================================================
void BP_ResetSetup()
{
   g_bias = BP_BIAS_NONE;
   g_setup_time = 0;
   g_impulse_move = 0.0;
   g_impulse_extreme = 0.0;
   g_pullback_extreme = 0.0;
   g_pullback_seen = false;
   g_burst_count = 0;
   g_last_burst_ms = 0;
   if(BP_CountPositions() == 0)
   {
      g_first_fill_price = 0.0;
      g_cycle_lot = 0.0;
      g_peak_profit = 0.0;
   }
}

void BP_EnterCooldown(const string why)
{
   BP_Log("Cooldown: " + why);
   BP_ResetSetup();
   g_state = BP_COOLDOWN;
   g_cooldown_until = TimeCurrent() + InpCooldownSec;
}

void BP_ManageOpen()
{
   const int openN = BP_CountPositions();
   if(openN <= 0)
   {
      // Cycle finished — record rough result via last peak/path
      // (Detailed deal history parsing omitted for single-file simplicity)
      BP_EnterCooldown("flat");
      return;
   }

   BP_EnsureEmergencySL();

   AdaptiveSignal sig = BP_BuildSignal();
   const ENUM_BP_BIAS openBias = BP_OpenBias();
   if(openBias != BP_BIAS_NONE) g_bias = openBias;

   const double pnl = BP_FloatingProfit();
   g_mode = BP_RiskMode(sig, pnl);

   // Smart exit first
   string newsReason;
   const bool newsBlock = BP_NewsBlocked(newsReason);
   if(BP_ShouldThreatClose(openBias, sig, pnl))
   {
      const double closedPnl = pnl;
      if(BP_CloseAll("threat-close pnl=" + DoubleToString(closedPnl, 2)))
      {
         BP_MemoryAdd(closedPnl);
         BP_EnterCooldown("threat-close");
      }
      return;
   }

   // Optional protect during news if already threatened lightly
   if(newsBlock && InpCloseOnNewsThreat && pnl >= BP_MinSecureMoney() &&
      (BP_CandleThreat(openBias) || (sig.valid && openBias == BP_BIAS_BUY && sig.downBias > 0.55) ||
       (sig.valid && openBias == BP_BIAS_SELL && sig.upBias > 0.55)))
   {
      if(BP_CloseAll("news-protect " + newsReason))
      {
         BP_MemoryAdd(pnl);
         BP_EnterCooldown("news-protect");
      }
      return;
   }

   // Adds only while still clean and same price
   if(g_mode != BP_MODE_LOCKDOWN && g_mode != BP_MODE_DEFENSIVE)
   {
      string reason;
      if(BP_CanOpenNewEntries(reason))
      {
         // Require continued bias agreement for adds
         if(sig.valid && sig.bias == openBias && BP_CandleAgrees(openBias))
         {
            // For adds, treat as continuation burst with pullback already satisfied
            if(g_state != BP_ENTER_BURST) g_state = BP_ENTER_BURST;
            BP_TryBurstEntry(sig);
         }
      }
   }
}

void BP_ProcessSetup(const AdaptiveSignal &sig)
{
   // Expire stale setups
   if(g_setup_time > 0 && TimeCurrent() - g_setup_time > InpSetupExpireSec)
   {
      BP_ResetSetup();
      g_state = BP_IDLE;
      return;
   }

   if(!sig.valid) return;

   // Detect / confirm impulse
   if(g_state == BP_IDLE || g_state == BP_BIAS_DETECT)
   {
      if(sig.bias != BP_BIAS_NONE && BP_CandleAgrees(sig.bias))
      {
         g_bias = sig.bias;
         g_setup_time = TimeCurrent();
         g_impulse_move = MathAbs(sig.netMove);
         g_impulse_extreme = BP_Mid();
         g_pullback_seen = false;
         g_pullback_extreme = g_impulse_extreme;
         g_burst_count = 0;
         g_state = BP_IMPULSE_CONFIRM;
         BP_Log("Impulse bias=" + (g_bias == BP_BIAS_BUY ? "BUY" : "SELL") +
                " imb=" + DoubleToString(MathMax(sig.upBias, sig.downBias), 2) +
                " win=" + IntegerToString(sig.windowSec) + "s" +
                " tps=" + DoubleToString(sig.ticksPerSec, 1));
      }
      else
      {
         g_state = BP_BIAS_DETECT;
      }
      return;
   }

   if(g_state == BP_IMPULSE_CONFIRM)
   {
      // Bias must hold
      if(sig.bias != g_bias)
      {
         // soft cancel if completely flipped
         if(sig.bias != BP_BIAS_NONE && sig.bias != g_bias)
         {
            BP_ResetSetup();
            g_state = BP_IDLE;
         }
         return;
      }

      const double mid = BP_Mid();
      if(g_bias == BP_BIAS_BUY)
      {
         if(mid > g_impulse_extreme) g_impulse_extreme = mid;
         g_impulse_move = MathMax(g_impulse_move, MathAbs(sig.netMove));
         // Transition to wait pullback once impulse established
         if(g_impulse_move >= BP_MinNetMove())
         {
            g_state = BP_WAIT_PULLBACK;
            g_pullback_extreme = mid;
         }
      }
      else if(g_bias == BP_BIAS_SELL)
      {
         if(mid < g_impulse_extreme || g_impulse_extreme <= 0.0) g_impulse_extreme = mid;
         g_impulse_move = MathMax(g_impulse_move, MathAbs(sig.netMove));
         if(g_impulse_move >= BP_MinNetMove())
         {
            g_state = BP_WAIT_PULLBACK;
            g_pullback_extreme = mid;
         }
      }
      return;
   }

   if(g_state == BP_WAIT_PULLBACK)
   {
      const double mid = BP_Mid();
      if(g_bias == BP_BIAS_BUY)
      {
         if(mid > g_impulse_extreme) g_impulse_extreme = mid;
         if(mid < g_pullback_extreme || !g_pullback_seen) g_pullback_extreme = mid;

         const double pb = g_impulse_extreme - mid;
         const double depth = (g_impulse_move > 0.0 ? pb / g_impulse_move : 0.0);

         if(depth >= InpPullbackMaxFrac)
         {
            BP_ResetSetup();
            g_state = BP_IDLE;
            BP_Log("Setup cancel: pullback too deep");
            return;
         }
         if(depth >= InpPullbackFrac)
            g_pullback_seen = true;

         // Resume = price turns back up after pullback + bias still buy
         if(g_pullback_seen && sig.bias == BP_BIAS_BUY && mid > g_pullback_extreme + BP_Point() * 2.0
            && BP_CandleAgrees(BP_BIAS_BUY))
         {
            g_state = BP_ENTER_BURST;
         }
      }
      else if(g_bias == BP_BIAS_SELL)
      {
         if(mid < g_impulse_extreme) g_impulse_extreme = mid;
         if(mid > g_pullback_extreme || !g_pullback_seen) g_pullback_extreme = mid;

         const double pb = mid - g_impulse_extreme;
         const double depth = (g_impulse_move > 0.0 ? pb / g_impulse_move : 0.0);

         if(depth >= InpPullbackMaxFrac)
         {
            BP_ResetSetup();
            g_state = BP_IDLE;
            BP_Log("Setup cancel: pullback too deep");
            return;
         }
         if(depth >= InpPullbackFrac)
            g_pullback_seen = true;

         if(g_pullback_seen && sig.bias == BP_BIAS_SELL && mid < g_pullback_extreme - BP_Point() * 2.0
            && BP_CandleAgrees(BP_BIAS_SELL))
         {
            g_state = BP_ENTER_BURST;
         }
      }
      return;
   }

   if(g_state == BP_ENTER_BURST)
   {
      // Keep bursting while allowed / same price / bias holds
      if(sig.bias != BP_BIAS_NONE && sig.bias != g_bias)
      {
         if(BP_CountPositions() > 0)
            g_state = BP_MANAGE;
         else
         {
            BP_ResetSetup();
            g_state = BP_IDLE;
         }
         return;
      }

      BP_TryBurstEntry(sig);

      if(BP_CountPositions() > 0)
      {
         // Continue short burst then manage
         const int openN = BP_CountPositions();
         const int allowed = BP_AllowedEntries(g_mode, sig);
         if(openN >= allowed || g_burst_count >= InpMaxBurstPerPulse)
            g_state = BP_MANAGE;
      }
   }
}

void BP_OnTickState()
{
   // Always push ticks / always-on engines
   BP_PushTick();

   // If positions exist, management has priority
   if(BP_CountPositions() > 0)
   {
      g_state = BP_MANAGE;
      BP_ManageOpen();
      return;
   }

   // Flat path
   if(g_state == BP_COOLDOWN)
   {
      if(TimeCurrent() >= g_cooldown_until)
      {
         g_state = BP_IDLE;
         BP_ResetSetup();
      }
      return;
   }

   string reason;
   if(!BP_CanOpenNewEntries(reason))
   {
      // Stay idle while blocked; engines still active via tick push/news checks
      if(g_state != BP_IDLE && g_state != BP_COOLDOWN)
      {
         BP_ResetSetup();
         g_state = BP_IDLE;
      }
      return;
   }

   AdaptiveSignal sig = BP_BuildSignal();
   g_mode = BP_RiskMode(sig, 0.0);
   if(g_mode == BP_MODE_LOCKDOWN)
   {
      BP_ResetSetup();
      g_state = BP_IDLE;
      return;
   }

   BP_ProcessSetup(sig);
}

//======================================================================
// HISTORY MEMORY (deal close)
//======================================================================
void BP_TrackHistoryDeal(const ulong deal)
{
   if(!HistoryDealSelect(deal)) return;
   if(HistoryDealGetString(deal, DEAL_SYMBOL) != g_symbol) return;
   if((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic) return;
   const long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY) return;
   const double pnl = HistoryDealGetDouble(deal, DEAL_PROFIT) +
                      HistoryDealGetDouble(deal, DEAL_SWAP) +
                      HistoryDealGetDouble(deal, DEAL_COMMISSION);
   BP_MemoryAdd(pnl);
}

//======================================================================
// LIFECYCLE
//======================================================================
int OnInit()
{
   if(!BP_ValidateSymbol())
      return INIT_FAILED;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   ENUM_ORDER_TYPE_FILLING fill;
   BP_SelectFilling(fill);
   trade.SetTypeFilling(fill);

   BP_TickInit();
   BP_MemoryInit();
   BP_ResetSetup();
   g_state = BP_IDLE;
   g_mode = BP_MODE_NORMAL;

   BP_Log("Init OK symbol=" + g_symbol +
          " family=" + (g_is_gold ? "XAUUSD" : (g_is_us30 ? "US30" : "GENERIC")) +
          " maxEntries=" + IntegerToString(InpMaxEntriesHard) +
          " session=" + (InpUseSessionFilter ? "NY-London" : "OFF") +
          " calendar=" + (InpUseCalendarFilter ? "ON" : "OFF"));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   BP_Log("Deinit reason=" + IntegerToString(reason) +
          " state=" + BP_StateName(g_state) +
          " mode=" + BP_ModeName(g_mode));
}

void OnTick()
{
   if(!g_symbol_ok) return;
   BP_OnTickState();
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;
   const ulong deal = trans.deal;
   if(deal == 0) return;

   if(!HistoryDealSelect(deal))
   {
      // try history refresh
      HistorySelect(TimeCurrent() - 86400, TimeCurrent() + 60);
      if(!HistoryDealSelect(deal)) return;
   }
   BP_TrackHistoryDeal(deal);
}

//+------------------------------------------------------------------+
