//+------------------------------------------------------------------+
//| EA_BalochPulse.mq5                                               |
//| COMPLIANCE BUILD v2.60                                           |
//|                                                                  |
//| Single-file EA. Behavior locked to audited architecture.         |
//| Minimal inputs only (account/broker/session clock).              |
//|                                                                  |
//| AUDITED RULES:                                                   |
//|  R1  NY-London session only (new entries)                        |
//|  R2  Hard blackout 20:30-20:40 & 21:30-21:40 local               |
//|  R3  FOMC/Fed decision block via calendar (other news OK)        |
//|  R4  Adaptive tick imbalance (no fixed 30-tick window)           |
//|  R5  Candle memory must agree before impulse/entry               |
//|  R6  Impulse -> small pullback -> enter                          |
//|  R7  Risk Manager decides mode + lot + entry count               |
//|  R8  Equity $30-$50 can open 2-3 when clean                      |
//|  R9  Hard max 15 entries                                         |
//|  R10 Same-price burst (one locked quote / one shot)              |
//|  R11 No martingale (same lot per cycle)                          |
//|  R12 Smart self-exit is primary exit                             |
//|  R13 No spread filter                                            |
//|  R14 XAUUSD + US30 same logic                                    |
//|  R15 Always-on engines + on-chart rule monitor                   |
//+------------------------------------------------------------------+
#property copyright "Mark Moslares"
#property link      "https://github.com/markazetro1123-cpu/mark-moslares"
#property version   "2.60"
#property description "BalochPulse COMPLIANCE v2.60 — audited architecture behavior"

#include <Trade/Trade.mqh>

//======================================================================
// MINIMAL INPUTS (not behavior knobs)
//======================================================================
input group "=== Account / Broker ==="
input long   InpMagic              = 260726;  // Magic number
input double InpRiskPercent        = 2.0;     // Risk % for Risk Manager lot
input double InpMinLot             = 0.01;    // Min lot floor
input double InpMaxLotCap          = 1.00;    // Max lot cap
input int    InpSlippagePoints     = 40;      // Broker deviation
input bool   InpAllowBuy           = true;    // Allow BUY
input bool   InpAllowSell          = true;    // Allow SELL

input group "=== Session Clock (PH default) ==="
input int    InpSessionTZOffsetHrs = 8;       // Local TZ vs GMT (PH=8)
input int    InpSessionStartHour   = 20;      // Session start hour
input int    InpSessionStartMinute = 0;       // Session start minute
input int    InpSessionEndHour     = 5;       // Session end hour
input int    InpSessionEndMinute   = 0;       // Session end minute

input group "=== Runtime ==="
input bool   InpPrintLogs          = true;    // Print rule logs

//======================================================================
// LOCKED ARCHITECTURE CONSTANTS
//======================================================================
const int    BP_MAX_ENTRIES        = 15;
const int    BP_TICK_CAP           = 1200;
const int    BP_MIN_TICKS          = 6;
const int    BP_WIN_MIN_SEC        = 2;
const int    BP_WIN_MAX_SEC        = 60;
const int    BP_SETUP_EXPIRE_SEC   = 45;
const int    BP_COOLDOWN_SEC       = 3;
const int    BP_FOMC_BLOCK_MIN     = 45;
const int    BP_MEMORY_SIZE        = 12;
const double BP_DD_DEFENSIVE       = 1.5;
const double BP_DD_LOCKDOWN        = 3.0;
const int    BP_LOSS_DEFENSIVE     = 2;
const int    BP_LOSS_LOCKDOWN      = 4;

//======================================================================
// TYPES
//======================================================================
enum ENUM_BP_STATE
{
   BP_IDLE = 0,
   BP_BIAS_DETECT,
   BP_IMPULSE,
   BP_PULLBACK,
   BP_BURST,
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
   long   time_ms;
   double mid;
   int    dir;
};

struct AdaptiveSignal
{
   bool         valid;
   double       upBias;
   double       downBias;
   double       netMove;
   double       ticksPerSec;
   double       movePerSec;
   double       threshold;
   double       strength;
   int          ticksUsed;
   int          windowSec;
   ENUM_BP_BIAS bias;
};

struct TradeMemory
{
   bool     used;
   bool     win;
   double   pnl;
   datetime time;
};

//======================================================================
// GLOBALS
//======================================================================
CTrade         trade;
string         g_symbol;
bool           g_symbol_ok = false;
bool           g_is_gold   = false;
bool           g_is_us30   = false;

TickSample     g_ticks[];
int            g_tick_cap   = 0;
int            g_tick_head  = 0;
int            g_tick_count = 0;
double         g_last_mid   = 0.0;
bool           g_tick_bootstrapped = false;

ENUM_BP_STATE  g_state = BP_IDLE;
ENUM_BP_BIAS   g_bias  = BP_BIAS_NONE;
ENUM_BP_MODE   g_mode  = BP_MODE_NORMAL;

datetime       g_setup_time     = 0;
datetime       g_cooldown_until = 0;
double         g_impulse_start  = 0.0;
double         g_impulse_extreme= 0.0;
double         g_impulse_move   = 0.0;
double         g_pullback_ext   = 0.0;
bool           g_pullback_seen  = false;

double         g_first_fill = 0.0;
double         g_cycle_lot  = 0.0;
double         g_peak_pnl   = 0.0;

int            g_loss_streak = 0;
int            g_win_streak  = 0;
TradeMemory    g_memory[];
int            g_mem_pos = 0;

datetime       g_news_check  = 0;
bool           g_news_block  = false;
string         g_news_reason = "";
string         g_rule_now    = "boot";
string         g_last_log    = "";
AdaptiveSignal g_last_sig;

//======================================================================
// UTILS
//======================================================================
void BP_Log(const string msg)
{
   if(!InpPrintLogs)
      return;
   if(msg == g_last_log)
      return;
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

double BP_ClampD(const double v, const double lo, const double hi)
{
   return MathMax(lo, MathMin(hi, v));
}

int BP_ClampI(const int v, const int lo, const int hi)
{
   return (int)MathMax(lo, MathMin(hi, v));
}

double BP_NormVol(double vol)
{
   const double vmin  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   const double vmax  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   const double vstep = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   if(vstep <= 0.0)
      return vmin;

   vol = MathFloor(vol / vstep + 1e-12) * vstep;
   vol = MathMax(vmin, MathMin(vmax, vol));
   vol = MathMax(InpMinLot, MathMin(InpMaxLotCap, vol));

   int digits = 2;
   if(vstep < 0.01)
      digits = 3;
   if(vstep >= 1.0)
      digits = 0;
   return NormalizeDouble(vol, digits);
}

bool BP_SelectFilling(ENUM_ORDER_TYPE_FILLING &filling)
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

double BP_StopsDist()
{
   const int stops  = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const int freeze = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return MathMax(stops, freeze) * BP_Point();
}

bool BP_TradeAllowed()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;
   if(SymbolInfoInteger(g_symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
      return false;
   return true;
}

double BP_Mid()
{
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   if(bid <= 0.0 || ask <= 0.0)
      return 0.0;
   return (bid + ask) * 0.5;
}

double BP_Unit()
{
   if(g_is_us30)
      return MathMax(0.8, 80.0 * BP_Point());
   return MathMax(0.08, 80.0 * BP_Point());
}

double BP_SamePriceBand()
{
   if(g_is_us30)
      return MathMax(1.5, 120.0 * BP_Point());
   return MathMax(0.15, 120.0 * BP_Point());
}

double BP_EmergencySL()
{
   if(g_is_us30)
      return MathMax(30.0, 1000.0 * BP_Point());
   return MathMax(4.0, 1000.0 * BP_Point());
}

double BP_MinSecureMoney()
{
   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq < 50.0)
      return MathMax(0.10, eq * 0.0025);
   if(eq < 200.0)
      return MathMax(0.25, eq * 0.0018);
   return MathMax(0.60, eq * 0.0012);
}

int BP_LocalMinuteOfDay()
{
   const datetime local = TimeGMT() + InpSessionTZOffsetHrs * 3600;
   MqlDateTime dt;
   TimeToStruct(local, dt);
   return dt.hour * 60 + dt.min;
}

bool BP_InMinuteWindow(const int now, const int startMin, const int endMin)
{
   if(startMin == endMin)
      return false;
   if(startMin < endMin)
      return (now >= startMin && now < endMin);
   return (now >= startMin || now < endMin);
}

string BP_Upper(string s)
{
   StringToUpper(s);
   return s;
}

string BP_ModeName(const ENUM_BP_MODE mode)
{
   if(mode == BP_MODE_AGGRESSIVE)
      return "AGGRESSIVE";
   if(mode == BP_MODE_DEFENSIVE)
      return "DEFENSIVE";
   if(mode == BP_MODE_LOCKDOWN)
      return "LOCKDOWN";
   return "NORMAL";
}

string BP_StateName(const ENUM_BP_STATE state)
{
   switch(state)
   {
      case BP_BIAS_DETECT: return "BIAS_DETECT";
      case BP_IMPULSE:     return "IMPULSE";
      case BP_PULLBACK:    return "PULLBACK";
      case BP_BURST:       return "BURST";
      case BP_MANAGE:      return "MANAGE";
      case BP_COOLDOWN:    return "COOLDOWN";
      default:             return "IDLE";
   }
}

string BP_BiasName(const ENUM_BP_BIAS bias)
{
   if(bias == BP_BIAS_BUY)
      return "BUY";
   if(bias == BP_BIAS_SELL)
      return "SELL";
   return "NONE";
}

//======================================================================
// R14 SYMBOL FAMILY
//======================================================================
bool BP_IsGoldSymbol(const string symbol)
{
   const string u = BP_Upper(symbol);
   if(StringFind(u, "XAUUSD") >= 0)
      return true;
   if(StringFind(u, "GOLD") >= 0 && StringFind(u, "GOLDF") < 0)
      return true;
   return false;
}

bool BP_IsUS30Symbol(const string symbol)
{
   const string u = BP_Upper(symbol);
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

bool BP_ValidateSymbol()
{
   g_symbol = _Symbol;
   g_is_gold = BP_IsGoldSymbol(g_symbol);
   g_is_us30 = BP_IsUS30Symbol(g_symbol);
   g_symbol_ok = (g_is_gold || g_is_us30);
   if(!g_symbol_ok)
   {
      BP_Log("COMPLIANCE FAIL R14: unsupported symbol " + g_symbol);
      return false;
   }
   return true;
}

//======================================================================
// R1 SESSION GUARD
//======================================================================
bool BP_SessionOK()
{
   const int now = BP_LocalMinuteOfDay();
   const int a = InpSessionStartHour * 60 + InpSessionStartMinute;
   const int b = InpSessionEndHour * 60 + InpSessionEndMinute;
   return BP_InMinuteWindow(now, a, b);
}

//======================================================================
// R2 HARD BLACKOUT + R3 FOMC ONLY (other news OK)
//======================================================================
bool BP_HardBlackout(string &reason)
{
   const int now = BP_LocalMinuteOfDay();
   if(BP_InMinuteWindow(now, 20 * 60 + 30, 20 * 60 + 40))
   {
      reason = "R2 hard blackout 20:30-20:40";
      return true;
   }
   if(BP_InMinuteWindow(now, 21 * 60 + 30, 21 * 60 + 40))
   {
      reason = "R2 hard blackout 21:30-21:40";
      return true;
   }
   return false;
}

bool BP_IsFomcEventName(const string name)
{
   string u = name;
   StringToUpper(u);
   if(StringFind(u, "FOMC") >= 0)
      return true;
   if(StringFind(u, "FEDERAL FUNDS") >= 0)
      return true;
   if(StringFind(u, "FED RATE") >= 0)
      return true;
   if(StringFind(u, "FEDERAL OPEN MARKET") >= 0)
      return true;
   if(StringFind(u, "MONETARY POLICY STATEMENT") >= 0)
      return true;
   if(StringFind(u, "FED INTEREST RATE DECISION") >= 0)
      return true;
   // US interest rate decision is treated as FOMC-class
   if(StringFind(u, "INTEREST RATE DECISION") >= 0)
      return true;
   return false;
}

bool BP_FomcCalendarBlock(string &reason)
{
   if(TimeCurrent() - g_news_check < 15 && g_news_check > 0)
   {
      reason = g_news_reason;
      return g_news_block;
   }

   g_news_check = TimeCurrent();
   g_news_block = false;
   g_news_reason = "";

   const datetime now  = TimeTradeServer();
   const datetime from = now - BP_FOMC_BLOCK_MIN * 60;
   const datetime to   = now + BP_FOMC_BLOCK_MIN * 60;

   MqlCalendarValue values[];
   int n = CalendarValueHistory(values, from, to, "US", NULL);
   if(n <= 0)
      n = CalendarValueHistory(values, from, to, NULL, NULL);
   if(n <= 0)
      return false;

   for(int i = 0; i < n; i++)
   {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev))
         continue;

      MqlCalendarCountry country;
      string code = "";
      if(CalendarCountryById(ev.country_id, country))
         code = country.code;
      if(code != "" && code != "US")
         continue;

      // COMPLIANCE: only FOMC-class events. Other news OK (per architecture).
      if(!BP_IsFomcEventName(ev.name))
         continue;

      const datetime eventTime = values[i].time;
      if(now >= eventTime - BP_FOMC_BLOCK_MIN * 60 &&
         now <= eventTime + BP_FOMC_BLOCK_MIN * 60)
      {
         g_news_block = true;
         g_news_reason = "R3 FOMC block: " + ev.name;
         reason = g_news_reason;
         return true;
      }
   }
   return false;
}

bool BP_NewsBlocked(string &reason)
{
   if(BP_HardBlackout(reason))
      return true;
   if(BP_FomcCalendarBlock(reason))
      return true;
   return false;
}

bool BP_CanOpenNewEntries(string &reason)
{
   // R13: intentionally NO spread filter here.
   if(!BP_SessionOK())
   {
      reason = "R1 outside NY-London session";
      return false;
   }
   if(BP_NewsBlocked(reason))
      return false;
   return true;
}

//======================================================================
// R4 ADAPTIVE TICK ENGINE
//======================================================================
void BP_TickInit()
{
   g_tick_cap = BP_TICK_CAP;
   ArrayResize(g_ticks, g_tick_cap);
   g_tick_head = 0;
   g_tick_count = 0;
   g_last_mid = 0.0;
   g_tick_bootstrapped = false;
}

void BP_PushOneTick(const double mid, const long time_ms)
{
   if(mid <= 0.0)
      return;

   int dir = 0;
   if(g_last_mid > 0.0)
   {
      if(mid > g_last_mid)
         dir = 1;
      else if(mid < g_last_mid)
         dir = -1;
   }
   g_last_mid = mid;

   g_ticks[g_tick_head].time_ms = time_ms;
   g_ticks[g_tick_head].mid = mid;
   g_ticks[g_tick_head].dir = dir;
   g_tick_head = (g_tick_head + 1) % g_tick_cap;
   if(g_tick_count < g_tick_cap)
      g_tick_count++;
}

void BP_BootstrapTicksFromM1Once()
{
   // Only bootstrap empty buffer once (tester/sparse start). Never every tick.
   if(g_tick_bootstrapped || g_tick_count >= BP_MIN_TICKS)
      return;

   double closes[];
   ArraySetAsSeries(closes, true);
   if(CopyClose(g_symbol, PERIOD_M1, 0, 8, closes) < 8)
      return;

   const long base_ms = (long)TimeCurrent() * 1000;
   for(int i = 7; i >= 0; i--)
      BP_PushOneTick(closes[i], base_ms - (long)i * 15000);

   g_tick_bootstrapped = true;
}

void BP_PushLiveTick()
{
   MqlTick tick;
   if(SymbolInfoTick(g_symbol, tick))
   {
      const double mid = (tick.bid + tick.ask) * 0.5;
      BP_PushOneTick(mid, (long)tick.time_msc);
   }
   BP_BootstrapTicksFromM1Once();
}

bool BP_GetTick(const int ageFromNewest, TickSample &out)
{
   if(ageFromNewest < 0 || ageFromNewest >= g_tick_count)
      return false;
   int idx = g_tick_head - 1 - ageFromNewest;
   while(idx < 0)
      idx += g_tick_cap;
   out = g_ticks[idx];
   return true;
}

AdaptiveSignal BP_BuildSignal()
{
   AdaptiveSignal sig;
   ZeroMemory(sig);
   sig.bias = BP_BIAS_NONE;

   if(g_tick_count < BP_MIN_TICKS)
      return sig;

   TickSample newest;
   if(!BP_GetTick(0, newest))
      return sig;

   int fastTicks = 0;
   double fastFirst = newest.mid;
   for(int i = 0; i < g_tick_count; i++)
   {
      TickSample sample;
      if(!BP_GetTick(i, sample))
         break;
      if(newest.time_ms - sample.time_ms > 3000)
         break;
      fastTicks++;
      fastFirst = sample.mid;
   }

   const double tps = (fastTicks > 1 ? fastTicks / 3.0 : 0.5);
   const double mps = MathAbs(newest.mid - fastFirst) / 3.0;
   sig.ticksPerSec = tps;
   sig.movePerSec = mps;

   // Adaptive window from tick density (NOT fixed 30 ticks)
   double targetSec = 16.0;
   if(tps >= 8.0)
      targetSec = 3.0;
   else if(tps >= 4.0)
      targetSec = 6.0;
   else if(tps >= 2.0)
      targetSec = 10.0;
   else if(tps >= 1.0)
      targetSec = 18.0;
   else
      targetSec = 35.0;

   const double unit = BP_Unit();
   if(mps > unit * 0.8)
      targetSec *= 0.75;
   if(mps < unit * 0.12)
      targetSec *= 1.25;

   const int windowSec = BP_ClampI((int)MathRound(targetSec), BP_WIN_MIN_SEC, BP_WIN_MAX_SEC);
   sig.windowSec = windowSec;

   const long windowMs = (long)windowSec * 1000;
   int up = 0;
   int down = 0;
   int used = 0;
   double firstMid = newest.mid;

   for(int i = 0; i < g_tick_count; i++)
   {
      TickSample sample;
      if(!BP_GetTick(i, sample))
         break;
      if(newest.time_ms - sample.time_ms > windowMs)
         break;
      used++;
      if(sample.dir > 0)
         up++;
      else if(sample.dir < 0)
         down++;
      firstMid = sample.mid;
   }

   if(used < BP_MIN_TICKS)
      return sig;

   const int directional = up + down;
   if(directional <= 0)
      return sig;

   sig.ticksUsed = used;
   sig.upBias = (double)up / (double)directional;
   sig.downBias = (double)down / (double)directional;
   sig.netMove = newest.mid - firstMid;

   double thr = 0.62;
   if(tps >= 5.0)
      thr = 0.55;
   else if(tps >= 2.5)
      thr = 0.58;
   else if(tps < 1.0)
      thr = 0.66;
   sig.threshold = thr;

   const double minMove = unit * 0.20;
   if(sig.upBias >= thr && sig.netMove >= minMove)
      sig.bias = BP_BIAS_BUY;
   else if(sig.downBias >= thr && sig.netMove <= -minMove)
      sig.bias = BP_BIAS_SELL;

   const double imb = MathMax(sig.upBias, sig.downBias);
   const double moveScore = BP_ClampD(MathAbs(sig.netMove) / MathMax(unit, BP_Point()), 0.0, 2.0) / 2.0;
   const double imbScore = BP_ClampD((imb - 0.50) / 0.30, 0.0, 1.0);
   sig.strength = BP_ClampD(0.55 * imbScore + 0.45 * moveScore, 0.0, 1.0);
   sig.valid = true;
   return sig;
}

//======================================================================
// R5 CANDLE MEMORY
//======================================================================
bool BP_CandleAgrees(const ENUM_BP_BIAS bias)
{
   if(bias == BP_BIAS_NONE)
      return false;

   double opens[], closes[], highs[], lows[];
   ArraySetAsSeries(opens, true);
   ArraySetAsSeries(closes, true);
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);

   if(CopyOpen(g_symbol, PERIOD_CURRENT, 0, 3, opens) < 3)
      return false;
   if(CopyClose(g_symbol, PERIOD_CURRENT, 0, 3, closes) < 3)
      return false;
   if(CopyHigh(g_symbol, PERIOD_CURRENT, 0, 3, highs) < 3)
      return false;
   if(CopyLow(g_symbol, PERIOD_CURRENT, 0, 3, lows) < 3)
      return false;

   const double body0 = closes[0] - opens[0];
   const double body1 = closes[1] - opens[1];
   const double range1 = MathMax(BP_Point(), highs[1] - lows[1]);
   const double closePos = (closes[1] - lows[1]) / range1;

   if(bias == BP_BIAS_BUY)
   {
      if(body1 < -range1 * 0.70 && closePos < 0.22)
         return false;
      return (body1 >= 0.0 || body0 >= 0.0 || closePos >= 0.50);
   }

   if(body1 > range1 * 0.70 && closePos > 0.78)
      return false;
   return (body1 <= 0.0 || body0 <= 0.0 || closePos <= 0.50);
}

bool BP_CandleThreat(const ENUM_BP_BIAS openBias)
{
   if(openBias == BP_BIAS_NONE)
      return false;

   double opens[], closes[], highs[], lows[];
   ArraySetAsSeries(opens, true);
   ArraySetAsSeries(closes, true);
   ArraySetAsSeries(highs, true);
   ArraySetAsSeries(lows, true);

   if(CopyOpen(g_symbol, PERIOD_CURRENT, 0, 2, opens) < 2)
      return false;
   if(CopyClose(g_symbol, PERIOD_CURRENT, 0, 2, closes) < 2)
      return false;
   if(CopyHigh(g_symbol, PERIOD_CURRENT, 0, 2, highs) < 2)
      return false;
   if(CopyLow(g_symbol, PERIOD_CURRENT, 0, 2, lows) < 2)
      return false;

   const double range = MathMax(BP_Point(), highs[0] - lows[0]);
   const double body = closes[0] - opens[0];
   if(openBias == BP_BIAS_BUY)
      return (body < -range * 0.32);
   return (body > range * 0.32);
}

//======================================================================
// POSITION HELPERS
//======================================================================
int BP_CountPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
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

ENUM_BP_BIAS BP_OpenBias()
{
   ENUM_BP_BIAS bias = BP_BIAS_NONE;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      const long type = PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_BUY)
      {
         if(bias == BP_BIAS_SELL)
            return BP_BIAS_NONE;
         bias = BP_BIAS_BUY;
      }
      else if(type == POSITION_TYPE_SELL)
      {
         if(bias == BP_BIAS_BUY)
            return BP_BIAS_NONE;
         bias = BP_BIAS_SELL;
      }
   }
   return bias;
}

double BP_FloatingProfit()
{
   double pnl = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      pnl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return pnl;
}

bool BP_CloseAll(const string why)
{
   bool ok = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if(!trade.PositionClose(ticket))
         ok = false;
   }
   if(ok)
   {
      g_rule_now = "R12 closed: " + why;
      BP_Log(g_rule_now);
   }
   return ok;
}

void BP_EnsureEmergencySL()
{
   const double dist = MathMax(BP_EmergencySL(), BP_StopsDist() + 2.0 * BP_Point());
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      if(PositionGetDouble(POSITION_SL) > 0.0)
         continue;

      const long type = PositionGetInteger(POSITION_TYPE);
      const double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      const double sl = (type == POSITION_TYPE_BUY)
                        ? BP_NormPrice(openPrice - dist)
                        : BP_NormPrice(openPrice + dist);
      trade.PositionModify(ticket, sl, PositionGetDouble(POSITION_TP));
   }
}

//======================================================================
// R7 RISK MANAGER + R8/R9/R11
//======================================================================
void BP_MemoryInit()
{
   ArrayResize(g_memory, BP_MEMORY_SIZE);
   for(int i = 0; i < BP_MEMORY_SIZE; i++)
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
   g_mem_pos = (g_mem_pos + 1) % BP_MEMORY_SIZE;

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
   for(int i = 0; i < BP_MEMORY_SIZE; i++)
   {
      if(!g_memory[i].used)
         continue;
      samples++;
      if(g_memory[i].win)
         wins++;
   }
   if(samples <= 0)
      return 0.5;
   return (double)wins / (double)samples;
}

double BP_LossPerLot(const double dist)
{
   if(dist <= 0.0)
      return 0.0;
   const double tickSize = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
   const double tickValue = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0)
      return 0.0;
   return (dist / tickSize) * tickValue;
}

double BP_MaxLotByMargin(const ENUM_ORDER_TYPE type, const double price)
{
   const double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   const double vmin = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   if(free <= 0.0)
      return vmin;

   double margin1 = 0.0;
   if(!OrderCalcMargin(type, g_symbol, 1.0, price, margin1) || margin1 <= 0.0)
   {
      double marginMin = 0.0;
      if(!OrderCalcMargin(type, g_symbol, vmin, price, marginMin) || marginMin <= 0.0)
         return vmin;
      margin1 = marginMin / vmin;
   }
   return BP_NormVol((free * 0.65) / margin1);
}

int BP_BaseEntriesByEquity(const double equity)
{
   // R8: $30-$50 zone already allows up to 3
   if(equity < 20.0)
      return 1;
   if(equity < 30.0)
      return 2;
   if(equity < 80.0)
      return 3;
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
   return BP_MAX_ENTRIES; // R9
}

ENUM_BP_MODE BP_RiskMode(const AdaptiveSignal &sig, const double floatingPnl)
{
   const double equity = MathMax(1.0, AccountInfoDouble(ACCOUNT_EQUITY));
   const double ddPct = (floatingPnl < 0.0 ? (-floatingPnl / equity) * 100.0 : 0.0);

   if(ddPct >= BP_DD_LOCKDOWN || g_loss_streak >= BP_LOSS_LOCKDOWN)
      return BP_MODE_LOCKDOWN;
   if(ddPct >= BP_DD_DEFENSIVE || g_loss_streak >= BP_LOSS_DEFENSIVE)
      return BP_MODE_DEFENSIVE;

   int samples = 0;
   const double winRate = BP_RecentWinRate(samples);
   const bool strong = (sig.valid && sig.bias != BP_BIAS_NONE && sig.strength >= 0.55);

   if(strong && ddPct < BP_DD_DEFENSIVE * 0.35 && (samples < 3 || winRate >= 0.45))
      return BP_MODE_AGGRESSIVE;
   if(strong && ddPct < BP_DD_DEFENSIVE * 0.50 && g_loss_streak == 0)
      return BP_MODE_AGGRESSIVE;
   return BP_MODE_NORMAL;
}

int BP_AllowedEntries(const ENUM_BP_MODE mode, const AdaptiveSignal &sig)
{
   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   int allowed = BP_ClampI(BP_BaseEntriesByEquity(equity), 1, BP_MAX_ENTRIES);

   if(mode == BP_MODE_LOCKDOWN)
      return 0;
   if(mode == BP_MODE_DEFENSIVE)
      return MathMax(1, allowed / 2);

   if(sig.valid)
   {
      if(sig.strength < 0.40)
         allowed = MathMax(1, allowed - 1);
      if(sig.strength >= 0.70 && mode == BP_MODE_AGGRESSIVE)
         allowed = MathMin(BP_MAX_ENTRIES, allowed + 1);
   }

   // R8 reinforce: small capital clean signal keeps 2-3 available
   if(equity >= 30.0 && equity < 80.0 && sig.valid && sig.strength >= 0.45)
      allowed = MathMax(allowed, 2);

   return BP_ClampI(allowed, 0, BP_MAX_ENTRIES);
}

double BP_CalcLot(const ENUM_ORDER_TYPE type, const double price, const ENUM_BP_MODE mode)
{
   // R11: same lot for whole cycle (no martingale)
   if(g_cycle_lot > 0.0 && BP_CountPositions() > 0)
      return BP_NormVol(g_cycle_lot);

   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   const double lossPerLot = BP_LossPerLot(BP_EmergencySL());

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

   if(mode == BP_MODE_AGGRESSIVE)
      lot *= 1.10;
   if(mode == BP_MODE_DEFENSIVE)
      lot *= 0.75;
   if(mode == BP_MODE_LOCKDOWN)
      lot = InpMinLot;

   lot = MathMin(lot, BP_MaxLotByMargin(type, price));
   return BP_NormVol(lot);
}

//======================================================================
// R10 SAME-PRICE BURST
//======================================================================
bool BP_OpenOne(const ENUM_BP_BIAS bias, const double lot, const double lockedPrice)
{
   if(bias == BP_BIAS_BUY && !InpAllowBuy)
      return false;
   if(bias == BP_BIAS_SELL && !InpAllowSell)
      return false;
   if(!BP_TradeAllowed())
      return false;

   ENUM_ORDER_TYPE_FILLING filling;
   BP_SelectFilling(filling);
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFilling(filling);

   const double dist = MathMax(BP_EmergencySL(), BP_StopsDist() + 2.0 * BP_Point());
   if(bias == BP_BIAS_BUY)
      return trade.Buy(lot, g_symbol, lockedPrice, BP_NormPrice(lockedPrice - dist), 0.0, "BP-BUY");
   return trade.Sell(lot, g_symbol, lockedPrice, BP_NormPrice(lockedPrice + dist), 0.0, "BP-SELL");
}

bool BP_FireSamePriceBurst(const AdaptiveSignal &sig)
{
   string reason;
   if(!BP_CanOpenNewEntries(reason))
   {
      g_rule_now = reason;
      BP_Log(g_rule_now);
      return false;
   }

   ENUM_BP_BIAS bias = g_bias;
   if(bias == BP_BIAS_NONE)
      bias = sig.bias;
   if(bias == BP_BIAS_NONE)
   {
      g_rule_now = "R6/R7 no bias";
      return false;
   }

   const ENUM_BP_BIAS openBias = BP_OpenBias();
   if(openBias != BP_BIAS_NONE && openBias != bias)
   {
      g_rule_now = "R10 one-way basket only";
      return false;
   }

   g_mode = BP_RiskMode(sig, BP_FloatingProfit());
   const int allowed = BP_AllowedEntries(g_mode, sig);
   int openCount = BP_CountPositions();

   if(g_mode == BP_MODE_LOCKDOWN)
   {
      g_rule_now = "R7 LOCKDOWN";
      return false;
   }
   if(allowed <= 0)
   {
      g_rule_now = "R7 zero allowed entries";
      return false;
   }
   if(openCount >= allowed)
   {
      g_rule_now = "R7 at allowed entries";
      return false;
   }
   if(openCount >= BP_MAX_ENTRIES)
   {
      g_rule_now = "R9 hard max 15";
      return false;
   }
   if(g_mode == BP_MODE_DEFENSIVE && openCount >= 1)
   {
      g_rule_now = "R7 DEFENSIVE no-add";
      return false;
   }

   int want = allowed - openCount;
   if(openCount == 0)
   {
      // First pulse: RM count, keep small-capital 2-3 behavior
      want = allowed;
      if(want > 3)
         want = 3;
   }
   else
   {
      want = 1; // continuation add only one, still same-price locked
   }

   const ENUM_ORDER_TYPE orderType = (bias == BP_BIAS_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   const double lockedPrice = (bias == BP_BIAS_BUY
                               ? SymbolInfoDouble(g_symbol, SYMBOL_ASK)
                               : SymbolInfoDouble(g_symbol, SYMBOL_BID));

   if(g_first_fill > 0.0 && MathAbs(lockedPrice - g_first_fill) > BP_SamePriceBand())
   {
      g_rule_now = "R10 skip: outside same-price band";
      BP_Log(g_rule_now);
      return false;
   }

   const double lot = BP_CalcLot(orderType, lockedPrice, g_mode);
   if(lot <= 0.0)
   {
      g_rule_now = "R7 lot=0";
      return false;
   }

   if(g_first_fill <= 0.0)
      g_first_fill = lockedPrice; // lock cycle price band

   int made = 0;
   for(int i = 0; i < want; i++)
   {
      // Re-validate band against live quote, but send lockedPrice for same-price intent
      const double live = (bias == BP_BIAS_BUY
                           ? SymbolInfoDouble(g_symbol, SYMBOL_ASK)
                           : SymbolInfoDouble(g_symbol, SYMBOL_BID));
      if(MathAbs(live - g_first_fill) > BP_SamePriceBand())
         break;

      if(!BP_OpenOne(bias, lot, g_first_fill))
      {
         BP_Log("R10 order fail retcode=" + IntegerToString((int)trade.ResultRetcode()));
         break;
      }

      if(g_cycle_lot <= 0.0)
         g_cycle_lot = lot; // R11 lock lot
      made++;
      openCount++;
      if(openCount >= allowed || openCount >= BP_MAX_ENTRIES)
         break;
   }

   if(made > 0)
   {
      g_bias = bias;
      g_state = BP_MANAGE;
      g_rule_now = "R10 same-price burst x" + IntegerToString(made) +
                   " @ " + DoubleToString(g_first_fill, BP_Digits()) +
                   " lot=" + DoubleToString(g_cycle_lot, 2) +
                   " mode=" + BP_ModeName(g_mode);
      BP_Log(g_rule_now);
      return true;
   }
   return false;
}

//======================================================================
// R12 SMART SELF-EXIT
//======================================================================
bool BP_ShouldThreatClose(const ENUM_BP_BIAS openBias, const AdaptiveSignal &sig, const double pnl)
{
   if(openBias == BP_BIAS_NONE)
      return false;

   const double minSecure = BP_MinSecureMoney();
   if(pnl > g_peak_pnl)
      g_peak_pnl = pnl;

   bool opposite = false;
   if(sig.valid)
   {
      if(openBias == BP_BIAS_BUY)
         opposite = (sig.downBias >= 0.58 && sig.netMove < 0.0);
      else
         opposite = (sig.upBias >= 0.58 && sig.netMove > 0.0);
   }

   const bool candleThreat = BP_CandleThreat(openBias);
   const bool hadProfit = (g_peak_pnl >= minSecure);
   const bool giveback = (hadProfit && pnl <= g_peak_pnl * 0.55);
   const bool flipRisk = (hadProfit && pnl < minSecure * 0.35 && (opposite || candleThreat));

   if(hadProfit && opposite && candleThreat)
      return true;
   if(hadProfit && giveback && (opposite || candleThreat))
      return true;
   if(flipRisk)
      return true;
   if(g_mode == BP_MODE_LOCKDOWN && pnl < 0.0 && opposite)
      return true;
   return false;
}

//======================================================================
// R15 MONITOR
//======================================================================
void BP_UpdateMonitor()
{
   string newsReason;
   const bool sessionOk = BP_SessionOK();
   const bool newsBlocked = BP_NewsBlocked(newsReason);
   const int openCount = BP_CountPositions();
   const int allowed = BP_AllowedEntries(g_mode, g_last_sig);
   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);

   const string text =
      "BalochPulse COMPLIANCE v2.60\n" +
      "Symbol: " + g_symbol + (g_is_gold ? " (XAUUSD)" : " (US30)") + "\n" +
      "R1 Session: " + (sessionOk ? "OK" : "BLOCK") + "\n" +
      "R2/R3 News: " + (newsBlocked ? newsReason : "OK (FOMC+blackout only)") + "\n" +
      "State: " + BP_StateName(g_state) + " | Mode: " + BP_ModeName(g_mode) + "\n" +
      "Bias: " + BP_BiasName(g_bias) + "\n" +
      "R4 Signal: up=" + DoubleToString(g_last_sig.upBias, 2) +
      " dn=" + DoubleToString(g_last_sig.downBias, 2) +
      " win=" + IntegerToString(g_last_sig.windowSec) + "s" +
      " str=" + DoubleToString(g_last_sig.strength, 2) + "\n" +
      "R7/R8/R9 Entries: " + IntegerToString(openCount) + "/" + IntegerToString(allowed) +
      " max15 eq=" + DoubleToString(equity, 2) + "\n" +
      "R10/R11: fill=" + (g_first_fill > 0.0 ? DoubleToString(g_first_fill, BP_Digits()) : "-") +
      " lot=" + (g_cycle_lot > 0.0 ? DoubleToString(g_cycle_lot, 2) : "-") + "\n" +
      "RuleNow: " + g_rule_now;

   Comment(text);
}

//======================================================================
// STATE MACHINE (R6 flow)
//======================================================================
void BP_ResetSetup(const bool clearBasket)
{
   g_bias = BP_BIAS_NONE;
   g_setup_time = 0;
   g_impulse_start = 0.0;
   g_impulse_extreme = 0.0;
   g_impulse_move = 0.0;
   g_pullback_ext = 0.0;
   g_pullback_seen = false;

   if(clearBasket && BP_CountPositions() == 0)
   {
      g_first_fill = 0.0;
      g_cycle_lot = 0.0;
      g_peak_pnl = 0.0;
   }
}

void BP_EnterCooldown(const string why)
{
   g_rule_now = "cooldown: " + why;
   BP_Log(g_rule_now);
   BP_ResetSetup(true);
   g_state = BP_COOLDOWN;
   g_cooldown_until = TimeCurrent() + BP_COOLDOWN_SEC;
}

void BP_ManageOpen()
{
   if(BP_CountPositions() <= 0)
   {
      BP_EnterCooldown("flat");
      return;
   }

   BP_EnsureEmergencySL();

   AdaptiveSignal sig = BP_BuildSignal();
   g_last_sig = sig;

   const ENUM_BP_BIAS openBias = BP_OpenBias();
   if(openBias != BP_BIAS_NONE)
      g_bias = openBias;

   const double pnl = BP_FloatingProfit();
   g_mode = BP_RiskMode(sig, pnl);

   string newsReason;
   const bool newsBlocked = BP_NewsBlocked(newsReason);

   if(BP_ShouldThreatClose(openBias, sig, pnl))
   {
      if(BP_CloseAll("R12 threat-close pnl=" + DoubleToString(pnl, 2)))
      {
         BP_MemoryAdd(pnl);
         BP_EnterCooldown("R12");
      }
      return;
   }

   if(newsBlocked && pnl >= BP_MinSecureMoney() &&
      (BP_CandleThreat(openBias) ||
       (sig.valid && openBias == BP_BIAS_BUY && sig.downBias > 0.55) ||
       (sig.valid && openBias == BP_BIAS_SELL && sig.upBias > 0.55)))
   {
      if(BP_CloseAll("R3/R12 news-protect " + newsReason))
      {
         BP_MemoryAdd(pnl);
         BP_EnterCooldown("news-protect");
      }
      return;
   }

   if(g_mode == BP_MODE_LOCKDOWN || g_mode == BP_MODE_DEFENSIVE)
   {
      g_rule_now = "R7 no-add mode " + BP_ModeName(g_mode);
      return;
   }

   string reason;
   if(!BP_CanOpenNewEntries(reason))
   {
      g_rule_now = reason;
      return;
   }

   if(sig.valid && sig.bias == openBias && BP_CandleAgrees(openBias) && sig.strength >= 0.45)
   {
      g_state = BP_BURST;
      BP_FireSamePriceBurst(sig);
   }
   else
   {
      g_rule_now = "R7 waiting clean continuation";
   }
}

void BP_ProcessSetup(const AdaptiveSignal &sig)
{
   if(g_setup_time > 0 && TimeCurrent() - g_setup_time > BP_SETUP_EXPIRE_SEC)
   {
      g_rule_now = "R6 setup expired";
      BP_ResetSetup(false);
      g_state = BP_IDLE;
      return;
   }

   if(!sig.valid)
   {
      g_rule_now = "R4 waiting adaptive ticks";
      return;
   }

   if(g_state == BP_IDLE || g_state == BP_BIAS_DETECT)
   {
      if(sig.bias != BP_BIAS_NONE && BP_CandleAgrees(sig.bias) && sig.strength >= 0.35)
      {
         g_bias = sig.bias;
         g_setup_time = TimeCurrent();
         g_impulse_start = BP_Mid();
         g_impulse_extreme = g_impulse_start;
         g_impulse_move = MathAbs(sig.netMove);
         g_pullback_seen = false;
         g_pullback_ext = g_impulse_start;
         g_state = BP_IMPULSE;
         g_rule_now = "R6 impulse " + BP_BiasName(g_bias);
         BP_Log(g_rule_now + " str=" + DoubleToString(sig.strength, 2) +
                " win=" + IntegerToString(sig.windowSec) + "s");
      }
      else
      {
         g_state = BP_BIAS_DETECT;
         g_rule_now = "R4/R5 scanning bias";
      }
      return;
   }

   if(g_state == BP_IMPULSE)
   {
      if(sig.bias != BP_BIAS_NONE && sig.bias != g_bias)
      {
         g_rule_now = "R6 bias flip cancel";
         BP_ResetSetup(false);
         g_state = BP_IDLE;
         return;
      }

      const double mid = BP_Mid();
      if(g_bias == BP_BIAS_BUY && mid > g_impulse_extreme)
         g_impulse_extreme = mid;
      if(g_bias == BP_BIAS_SELL && (g_impulse_extreme <= 0.0 || mid < g_impulse_extreme))
         g_impulse_extreme = mid;

      g_impulse_move = MathMax(g_impulse_move, MathAbs(mid - g_impulse_start));
      if(g_impulse_move >= BP_Unit() * 0.20)
      {
         g_state = BP_PULLBACK;
         g_pullback_ext = mid;
         g_rule_now = "R6 wait pullback";
      }
      else
      {
         g_rule_now = "R6 building impulse";
      }
      return;
   }

   if(g_state == BP_PULLBACK)
   {
      const double mid = BP_Mid();
      const double unit = BP_Unit();

      if(g_bias == BP_BIAS_BUY)
      {
         if(mid > g_impulse_extreme)
            g_impulse_extreme = mid;
         if(!g_pullback_seen || mid < g_pullback_ext)
            g_pullback_ext = mid;

         const double pullback = g_impulse_extreme - mid;
         if(pullback >= unit * 1.25)
         {
            g_rule_now = "R6 pullback too deep";
            BP_ResetSetup(false);
            g_state = BP_IDLE;
            return;
         }
         if(pullback >= unit * 0.12)
            g_pullback_seen = true;

         if(g_pullback_seen &&
            sig.bias == BP_BIAS_BUY &&
            mid > g_pullback_ext + unit * 0.04 &&
            BP_CandleAgrees(BP_BIAS_BUY))
         {
            g_state = BP_BURST;
            g_rule_now = "R6 pullback done -> BURST";
         }
         else
         {
            g_rule_now = (g_pullback_seen ? "R6 waiting resume" : "R6 waiting pullback");
         }
      }
      else if(g_bias == BP_BIAS_SELL)
      {
         if(mid < g_impulse_extreme)
            g_impulse_extreme = mid;
         if(!g_pullback_seen || mid > g_pullback_ext)
            g_pullback_ext = mid;

         const double pullback = mid - g_impulse_extreme;
         if(pullback >= unit * 1.25)
         {
            g_rule_now = "R6 pullback too deep";
            BP_ResetSetup(false);
            g_state = BP_IDLE;
            return;
         }
         if(pullback >= unit * 0.12)
            g_pullback_seen = true;

         if(g_pullback_seen &&
            sig.bias == BP_BIAS_SELL &&
            mid < g_pullback_ext - unit * 0.04 &&
            BP_CandleAgrees(BP_BIAS_SELL))
         {
            g_state = BP_BURST;
            g_rule_now = "R6 pullback done -> BURST";
         }
         else
         {
            g_rule_now = (g_pullback_seen ? "R6 waiting resume" : "R6 waiting pullback");
         }
      }
      return;
   }

   if(g_state == BP_BURST)
   {
      if(sig.bias != BP_BIAS_NONE && sig.bias != g_bias)
      {
         if(BP_CountPositions() > 0)
            g_state = BP_MANAGE;
         else
         {
            BP_ResetSetup(false);
            g_state = BP_IDLE;
         }
         g_rule_now = "R6 bias lost in burst";
         return;
      }

      BP_FireSamePriceBurst(sig);
      if(BP_CountPositions() > 0)
         g_state = BP_MANAGE;
   }
}

void BP_OnTickState()
{
   // R15 always-on tick ingest
   BP_PushLiveTick();

   if(BP_CountPositions() > 0)
   {
      g_state = BP_MANAGE;
      BP_ManageOpen();
      BP_UpdateMonitor();
      return;
   }

   if(g_state == BP_COOLDOWN)
   {
      if(TimeCurrent() >= g_cooldown_until)
      {
         g_state = BP_IDLE;
         BP_ResetSetup(true);
         g_rule_now = "ready";
      }
      else
      {
         g_rule_now = "cooldown";
      }
      BP_UpdateMonitor();
      return;
   }

   string reason;
   if(!BP_CanOpenNewEntries(reason))
   {
      if(g_state != BP_IDLE && g_state != BP_COOLDOWN)
      {
         BP_ResetSetup(false);
         g_state = BP_IDLE;
      }
      g_rule_now = reason;
      g_last_sig = BP_BuildSignal(); // engines remain active
      BP_UpdateMonitor();
      return;
   }

   AdaptiveSignal sig = BP_BuildSignal();
   g_last_sig = sig;
   g_mode = BP_RiskMode(sig, 0.0);
   if(g_mode == BP_MODE_LOCKDOWN)
   {
      BP_ResetSetup(false);
      g_state = BP_IDLE;
      g_rule_now = "R7 LOCKDOWN";
      BP_UpdateMonitor();
      return;
   }

   BP_ProcessSetup(sig);
   BP_UpdateMonitor();
}

//======================================================================
// MEMORY FROM DEALS
//======================================================================
void BP_TrackHistoryDeal(const ulong deal)
{
   if(!HistoryDealSelect(deal))
      return;
   if(HistoryDealGetString(deal, DEAL_SYMBOL) != g_symbol)
      return;
   if((long)HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic)
      return;

   const long entry = HistoryDealGetInteger(deal, DEAL_ENTRY);
   if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY)
      return;

   const double pnl = HistoryDealGetDouble(deal, DEAL_PROFIT) +
                      HistoryDealGetDouble(deal, DEAL_SWAP) +
                      HistoryDealGetDouble(deal, DEAL_COMMISSION);
   BP_MemoryAdd(pnl);
}

bool BP_RunComplianceSelfCheck()
{
   bool ok = true;

   if(BP_MAX_ENTRIES != 15)
   {
      BP_Log("COMPLIANCE FAIL R9 max entries");
      ok = false;
   }

   // R13 sanity: no spread-input exists; guarded by design.
   // R11 sanity: cycle lot lock path exists via g_cycle_lot.
   if(InpRiskPercent <= 0.0)
   {
      BP_Log("COMPLIANCE WARN: RiskPercent <= 0");
      ok = false;
   }
   if(InpSessionTZOffsetHrs < -12 || InpSessionTZOffsetHrs > 14)
   {
      BP_Log("COMPLIANCE FAIL: invalid TZ offset");
      ok = false;
   }

   if(ok)
      BP_Log("COMPLIANCE SELF-CHECK PASS v2.60 (R1-R15 mapped)");
   return ok;
}

//======================================================================
// LIFECYCLE
//======================================================================
int OnInit()
{
   if(!BP_ValidateSymbol())
      return INIT_FAILED;

   if(!BP_RunComplianceSelfCheck())
      return INIT_FAILED;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);

   ENUM_ORDER_TYPE_FILLING filling;
   BP_SelectFilling(filling);
   trade.SetTypeFilling(filling);

   BP_TickInit();
   BP_MemoryInit();
   BP_ResetSetup(true);

   g_state = BP_IDLE;
   g_mode = BP_MODE_NORMAL;
   g_rule_now = "COMPLIANCE v2.60 ready";

   BP_Log("COMPLIANCE v2.60 ready | R1 session | R2 blackout | R3 FOMC | R4 adaptive tick | R5 candle | R6 pullback | R7 RM | R8 2-3@$30-50 | R9 max15 | R10 same-price | R11 no-martingale | R12 smart-exit | R13 no-spread-filter | R14 XAU/US30");
   BP_UpdateMonitor();
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Comment("");
   BP_Log("deinit reason=" + IntegerToString(reason));
}

void OnTick()
{
   if(!g_symbol_ok)
      return;
   BP_OnTickState();
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   // Touch params to avoid unused-parameter warnings
   if(request.volume < 0.0 || result.retcode == 0)
   {
      // no-op
   }

   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(trans.deal == 0)
      return;

   if(!HistoryDealSelect(trans.deal))
   {
      HistorySelect(TimeCurrent() - 86400, TimeCurrent() + 60);
      if(!HistoryDealSelect(trans.deal))
         return;
   }
   BP_TrackHistoryDeal(trans.deal);
}
//+------------------------------------------------------------------+
