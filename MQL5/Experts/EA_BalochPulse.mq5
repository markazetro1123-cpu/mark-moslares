//+------------------------------------------------------------------+
//| EA_BalochPulse.mq5                                               |
//| Architecture-locked Adaptive Pulse EA (XAUUSD + US30)            |
//|                                                                  |
//| SINGLE FILE — copy this one only.                                |
//|                                                                  |
//| Behavior is INSIDE the engines (not tunable filter soup).         |
//| Inputs are only identity / broker / risk / session clock.        |
//|                                                                  |
//| Always-on engines:                                               |
//|  1) Session Guard (NY-London)                                    |
//|  2) News/FOMC Guard + hard PM blackouts                          |
//|  3) Adaptive Tick Engine                                         |
//|  4) Candle Memory                                                |
//|  5) Risk Manager (CEO: lot + entries + mode)                     |
//|  6) Same-price Burst Entry Engine                                |
//|  7) Smart Self-Exit Brain                                        |
//+------------------------------------------------------------------+
#property copyright "Mark Moslares"
#property link      "https://github.com/markazetro1123-cpu/mark-moslares"
#property version   "2.00"
#property description "BalochPulse architecture v2: brains inside engines, minimal inputs"

#include <Trade/Trade.mqh>

//======================================================================
// MINIMAL INPUTS (not behavior knobs)
//======================================================================
input group "=== Account / Broker ==="
input long   InpMagic              = 260726;  // Magic number
input double InpRiskPercent        = 2.0;     // Risk % used by Risk Manager lot brain
input double InpMinLot             = 0.01;    // Broker min lot floor
input double InpMaxLotCap          = 1.00;    // Hard lot cap
input int    InpSlippagePoints     = 40;      // Broker deviation
input bool   InpAllowBuy           = true;
input bool   InpAllowSell          = true;

input group "=== Session Clock (PH default) ==="
input int    InpSessionTZOffsetHrs = 8;       // Local TZ vs GMT (PH=8)
input int    InpSessionStartHour   = 20;      // NY-London start (local)
input int    InpSessionStartMinute = 0;
input int    InpSessionEndHour     = 5;       // NY-London end (local)
input int    InpSessionEndMinute   = 0;

input group "=== Runtime ==="
input bool   InpPrintLogs          = true;

//======================================================================
// ARCHITECTURE CONSTANTS (locked behavior — not inputs)
//======================================================================
const int    BP_MAX_ENTRIES_HARD       = 15;
const int    BP_TICK_BUFFER            = 1000;
const int    BP_WINDOW_MIN_SEC         = 2;
const int    BP_WINDOW_MAX_SEC         = 60;
const int    BP_MIN_TICKS              = 6;
const int    BP_BURST_GAP_MS           = 200;
const int    BP_MAX_BURST_PULSE        = 3;
const int    BP_SETUP_EXPIRE_SEC       = 40;
const int    BP_COOLDOWN_SEC           = 3;
const int    BP_NEWS_BUFFER_MIN        = 8;
const int    BP_FOMC_BLOCK_MIN         = 45;
const int    BP_MEMORY_SIZE            = 12;

// Risk Manager personality targets: big win potential, small DD
const double BP_DD_DEFENSIVE_PCT       = 1.5;
const double BP_DD_LOCKDOWN_PCT        = 3.0;
const int    BP_LOSS_DEFENSIVE         = 2;
const int    BP_LOSS_LOCKDOWN          = 4;

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
   long   time_ms;
   double mid;
   int    dir;
};

struct AdaptiveSignal
{
   bool          valid;
   double        upBias;
   double        downBias;
   double        netMove;
   double        ticksPerSec;
   double        movePerSec;
   int           ticksUsed;
   int           windowSec;
   double        threshold;
   double        strength; // 0..1 Risk Manager uses this
   ENUM_BP_BIAS  bias;
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
CTrade trade;

string g_symbol;
bool   g_symbol_ok = false;
bool   g_is_gold   = false;
bool   g_is_us30   = false;

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
// LOG / UTILS
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

double BP_Unit()
{
   if(g_is_us30) return MathMax(0.8, 80.0 * BP_Point());
   return MathMax(0.08, 80.0 * BP_Point());
}

double BP_SamePriceBand()
{
   // Architecture: same price / tiny slippage only
   if(g_is_us30) return MathMax(2.0, 180.0 * BP_Point());
   return MathMax(0.20, 180.0 * BP_Point());
}

double BP_EmergencyStop()
{
   // Safety net only — Exit Brain is main exit
   if(g_is_us30) return MathMax(30.0, 1000.0 * BP_Point());
   return MathMax(4.0, 1000.0 * BP_Point());
}

double BP_MinSecureMoney()
{
   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq < 50.0) return MathMax(0.10, eq * 0.0025);
   if(eq < 200.0) return MathMax(0.25, eq * 0.0018);
   return MathMax(0.60, eq * 0.0012);
}

ulong BP_NowMs()
{
   return (ulong)GetTickCount64();
}

int BP_ClampI(const int v, const int lo, const int hi)
{
   return (int)MathMax(lo, MathMin(hi, v));
}

double BP_ClampD(const double v, const double lo, const double hi)
{
   return MathMax(lo, MathMin(hi, v));
}

int BP_LocalMinuteOfDay()
{
   const datetime tz = TimeGMT() + InpSessionTZOffsetHrs * 3600;
   MqlDateTime dt;
   TimeToStruct(tz, dt);
   return dt.hour * 60 + dt.min;
}

bool BP_InMinuteWindow(const int now, const int a, const int b)
{
   if(a == b) return false;
   if(a < b) return (now >= a && now < b);
   return (now >= a || now < b);
}

string BP_ModeName(const ENUM_BP_MODE m)
{
   if(m == BP_MODE_AGGRESSIVE) return "AGGRESSIVE";
   if(m == BP_MODE_DEFENSIVE)  return "DEFENSIVE";
   if(m == BP_MODE_LOCKDOWN)   return "LOCKDOWN";
   return "NORMAL";
}

string BP_Upper(string s)
{
   StringToUpper(s);
   return s;
}

//======================================================================
// SYMBOL FAMILY (XAUUSD + US30, same logic)
//======================================================================
bool BP_IsGoldSymbol(const string s)
{
   const string u = BP_Upper(s);
   return (StringFind(u, "XAUUSD") >= 0 || (StringFind(u, "GOLD") >= 0 && StringFind(u, "GOLDF") < 0));
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
      BP_Log("Unsupported symbol: " + g_symbol + " (XAUUSD / US30 family only)");
      return false;
   }
   return true;
}

//======================================================================
// ENGINE 1: SESSION GUARD (NY-London only)
//======================================================================
bool BP_InNyLondonSession()
{
   const int now = BP_LocalMinuteOfDay();
   const int a = InpSessionStartHour * 60 + InpSessionStartMinute;
   const int b = InpSessionEndHour * 60 + InpSessionEndMinute;
   return BP_InMinuteWindow(now, a, b);
}

//======================================================================
// ENGINE 2: NEWS / FOMC GUARD
//======================================================================
bool BP_InHardBlackout(string &reason)
{
   const int now = BP_LocalMinuteOfDay();
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
   if(TimeCurrent() - g_last_news_check < 15 && g_last_news_check > 0)
   {
      reason = g_news_reason;
      return g_news_block;
   }
   g_last_news_check = TimeCurrent();
   g_news_block = false;
   g_news_reason = "";

   const datetime now = TimeTradeServer();
   const datetime from = now - BP_FOMC_BLOCK_MIN * 60;
   const datetime to   = now + BP_FOMC_BLOCK_MIN * 60;

   MqlCalendarValue values[];
   int n = CalendarValueHistory(values, from, to, "US", NULL);
   if(n <= 0)
      n = CalendarValueHistory(values, from, to, NULL, NULL);
   if(n <= 0) return false;

   for(int i = 0; i < n; i++)
   {
      MqlCalendarEvent ev;
      if(!CalendarEventById(values[i].event_id, ev)) continue;

      MqlCalendarCountry co;
      string country = "";
      if(CalendarCountryById(ev.country_id, co))
         country = co.code;
      if(country != "" && country != "US")
         continue;

      const bool isFomc = BP_IsFomcText(ev.name);
      const bool highImpact = (ev.importance == CALENDAR_IMPORTANCE_HIGH);
      // Architecture: high-impact USD + FOMC blocked; other news OK
      if(!isFomc && !highImpact)
         continue;

      const datetime eventTime = values[i].time;
      const int blockMin = isFomc ? BP_FOMC_BLOCK_MIN : BP_NEWS_BUFFER_MIN;
      if(now >= eventTime - blockMin * 60 && now <= eventTime + blockMin * 60)
      {
         g_news_block = true;
         g_news_reason = (isFomc ? "FOMC: " : "High-impact USD: ") + ev.name;
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
// ENGINE 3: ADAPTIVE TICK ENGINE
//======================================================================
void BP_TickInit()
{
   g_tick_cap = BP_TICK_BUFFER;
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
   g_ticks[g_tick_head].mid = mid;
   g_ticks[g_tick_head].dir = dir;
   g_tick_head = (g_tick_head + 1) % g_tick_cap;
   if(g_tick_count < g_tick_cap) g_tick_count++;
}

bool BP_GetTick(const int age, TickSample &out)
{
   if(age < 0 || age >= g_tick_count) return false;
   int idx = g_tick_head - 1 - age;
   while(idx < 0) idx += g_tick_cap;
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
   if(!BP_GetTick(0, newest)) return sig;

   // Measure market speed (architecture: adaptive seconds from tick density)
   int fastTicks = 0;
   double fastFirst = newest.mid;
   for(int i = 0; i < g_tick_count; i++)
   {
      TickSample ts;
      if(!BP_GetTick(i, ts)) break;
      if(newest.time_ms - ts.time_ms > 3000) break;
      fastTicks++;
      fastFirst = ts.mid;
   }

   const double tps = (fastTicks > 1 ? fastTicks / 3.0 : 0.5);
   const double mps = MathAbs(newest.mid - fastFirst) / 3.0;
   sig.ticksPerSec = tps;
   sig.movePerSec = mps;

   // Adaptive window:
   // fast market -> short window; slow -> longer
   double target = 16.0;
   if(tps >= 8.0) target = 3.0;
   else if(tps >= 4.0) target = 6.0;
   else if(tps >= 2.0) target = 10.0;
   else if(tps >= 1.0) target = 18.0;
   else target = 35.0;

   const double unit = BP_Unit();
   if(mps > unit * 0.8) target *= 0.75;
   if(mps < unit * 0.12) target *= 1.25;

   const int winSec = BP_ClampI((int)MathRound(target), BP_WINDOW_MIN_SEC, BP_WINDOW_MAX_SEC);
   sig.windowSec = winSec;

   const long winMs = (long)winSec * 1000;
   int up = 0, down = 0, used = 0;
   double firstMid = newest.mid;

   for(int i = 0; i < g_tick_count; i++)
   {
      TickSample ts;
      if(!BP_GetTick(i, ts)) break;
      if(newest.time_ms - ts.time_ms > winMs) break;
      used++;
      if(ts.dir > 0) up++;
      else if(ts.dir < 0) down++;
      firstMid = ts.mid;
   }

   if(used < BP_MIN_TICKS) return sig;
   const int dirTicks = up + down;
   if(dirTicks <= 0) return sig;

   sig.ticksUsed = used;
   sig.upBias = (double)up / (double)dirTicks;
   sig.downBias = (double)down / (double)dirTicks;
   sig.netMove = newest.mid - firstMid;

   // Adaptive threshold: quieter market needs clearer imbalance
   double thr = 0.62;
   if(tps >= 5.0) thr = 0.55;
   else if(tps >= 2.5) thr = 0.58;
   else if(tps < 1.0) thr = 0.66;
   sig.threshold = thr;

   const double minMove = unit * 0.25;
   if(sig.upBias >= thr && sig.netMove >= minMove)
      sig.bias = BP_BIAS_BUY;
   else if(sig.downBias >= thr && sig.netMove <= -minMove)
      sig.bias = BP_BIAS_SELL;

   // Strength score for Risk Manager common-sense decisions
   const double imb = MathMax(sig.upBias, sig.downBias);
   const double moveScore = BP_ClampD(MathAbs(sig.netMove) / MathMax(unit, BP_Point()), 0.0, 2.0) / 2.0;
   const double imbScore = BP_ClampD((imb - 0.50) / 0.30, 0.0, 1.0);
   sig.strength = BP_ClampD(0.55 * imbScore + 0.45 * moveScore, 0.0, 1.0);

   sig.valid = true;
   return sig;
}

//======================================================================
// ENGINE 4: CANDLE MEMORY
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
      if(body1 < -range1 * 0.70 && closePos1 < 0.22) return false;
      if(body0 < -MathAbs(body1) && body0 < 0.0 && closePos1 < 0.35) return false;
      return (body1 >= 0.0 || body0 >= 0.0 || closePos1 >= 0.50);
   }

   if(body1 > range1 * 0.70 && closePos1 > 0.78) return false;
   if(body0 > MathAbs(body1) && body0 > 0.0 && closePos1 > 0.65) return false;
   return (body1 <= 0.0 || body0 <= 0.0 || closePos1 <= 0.50);
}

bool BP_CandleThreat(const ENUM_BP_BIAS openBias)
{
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
   if(openBias == BP_BIAS_BUY) return (body < -range * 0.32);
   return (body > range * 0.32);
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
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
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
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      const long type = PositionGetInteger(POSITION_TYPE);
      if(type == POSITION_TYPE_BUY)
      {
         if(b == BP_BIAS_SELL) return BP_BIAS_NONE;
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
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
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
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
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
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(!trade.PositionClose(ticket))
      {
         ok = false;
         BP_Log("Close fail #" + IntegerToString((int)ticket));
      }
   }
   if(ok) BP_Log("Closed all: " + why);
   return ok;
}

void BP_EnsureEmergencySL()
{
   const double dist = MathMax(BP_EmergencyStop(), BP_StopsDist() + 2.0 * BP_Point());
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
      if(PositionGetDouble(POSITION_SL) > 0.0) continue;

      const long type = PositionGetInteger(POSITION_TYPE);
      const double open = PositionGetDouble(POSITION_PRICE_OPEN);
      const double sl = (type == POSITION_TYPE_BUY)
                        ? BP_NormPrice(open - dist)
                        : BP_NormPrice(open + dist);
      trade.PositionModify(ticket, sl, PositionGetDouble(POSITION_TP));
   }
}

//======================================================================
// ENGINE 5: RISK MANAGER (CEO BRAIN)
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

   if(pnl > 0.0) { g_win_streak++; g_loss_streak = 0; }
   else if(pnl < 0.0) { g_loss_streak++; g_win_streak = 0; }
}

double BP_RecentWinRate(int &samples)
{
   int wins = 0;
   samples = 0;
   for(int i = 0; i < BP_MEMORY_SIZE; i++)
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

// Architecture equity intelligence:
// $30-$50 can already do 2-3 entries if clean
int BP_BaseEntriesByEquity(const double eq)
{
   if(eq < 20.0)   return 1;
   if(eq < 30.0)   return 2;
   if(eq < 80.0)   return 3;
   if(eq < 150.0)  return 4;
   if(eq < 300.0)  return 6;
   if(eq < 600.0)  return 8;
   if(eq < 1200.0) return 11;
   if(eq < 2500.0) return 13;
   return BP_MAX_ENTRIES_HARD;
}

ENUM_BP_MODE BP_RiskMode(const AdaptiveSignal &sig, const double floatingPnl)
{
   const double eq = MathMax(1.0, AccountInfoDouble(ACCOUNT_EQUITY));
   const double ddPct = (floatingPnl < 0.0 ? (-floatingPnl / eq) * 100.0 : 0.0);

   if(ddPct >= BP_DD_LOCKDOWN_PCT || g_loss_streak >= BP_LOSS_LOCKDOWN)
      return BP_MODE_LOCKDOWN;
   if(ddPct >= BP_DD_DEFENSIVE_PCT || g_loss_streak >= BP_LOSS_DEFENSIVE)
      return BP_MODE_DEFENSIVE;

   int samples = 0;
   const double wr = BP_RecentWinRate(samples);
   const bool cleanStrong = (sig.valid && sig.bias != BP_BIAS_NONE && sig.strength >= 0.55);

   // Common sense: expand only when clean + DD calm
   if(cleanStrong && ddPct < BP_DD_DEFENSIVE_PCT * 0.35 && (samples < 3 || wr >= 0.45))
      return BP_MODE_AGGRESSIVE;
   if(cleanStrong && ddPct < BP_DD_DEFENSIVE_PCT * 0.50 && g_loss_streak == 0)
      return BP_MODE_AGGRESSIVE;

   return BP_MODE_NORMAL;
}

int BP_AllowedEntries(const ENUM_BP_MODE mode, const AdaptiveSignal &sig)
{
   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   int allowed = BP_BaseEntriesByEquity(eq);
   allowed = BP_ClampI(allowed, 1, BP_MAX_ENTRIES_HARD);

   if(mode == BP_MODE_LOCKDOWN) return 0;
   if(mode == BP_MODE_DEFENSIVE) return MathMax(1, allowed / 2);

   // Risk Manager quality adjust
   if(sig.valid)
   {
      if(sig.strength < 0.40) allowed = MathMax(1, allowed - 1);
      if(sig.strength >= 0.70 && mode == BP_MODE_AGGRESSIVE)
         allowed = MathMin(BP_MAX_ENTRIES_HARD, allowed + 1);
   }

   // Architecture note: $30-$50 intelligent 2-3 when clean
   if(eq >= 30.0 && eq < 80.0 && mode == BP_MODE_AGGRESSIVE)
      allowed = MathMax(allowed, 2);

   return BP_ClampI(allowed, 0, BP_MAX_ENTRIES_HARD);
}

double BP_CalcLot(const ENUM_ORDER_TYPE type, const double price, const ENUM_BP_MODE mode)
{
   // No martingale: same lot for whole cycle
   if(g_cycle_lot > 0.0 && BP_CountPositions() > 0)
      return BP_NormVol(g_cycle_lot);

   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   const double lossPerLot = BP_LossPerLot(BP_EmergencyStop());

   double lot = InpMinLot;
   if(lossPerLot > 0.0)
      lot = (eq * InpRiskPercent / 100.0) / lossPerLot;

   // Equity growth steps (not martingale)
   if(eq >= 100.0)  lot = MathMax(lot, InpMinLot * 2.0);
   if(eq >= 250.0)  lot = MathMax(lot, InpMinLot * 3.0);
   if(eq >= 500.0)  lot = MathMax(lot, InpMinLot * 5.0);
   if(eq >= 1000.0) lot = MathMax(lot, InpMinLot * 8.0);
   if(eq >= 2000.0) lot = MathMax(lot, InpMinLot * 12.0);

   if(mode == BP_MODE_AGGRESSIVE) lot *= 1.10;
   if(mode == BP_MODE_DEFENSIVE)  lot *= 0.75;
   if(mode == BP_MODE_LOCKDOWN)   lot = InpMinLot;

   lot = MathMin(lot, BP_MaxLotMargin(type, price));
   return BP_NormVol(lot);
}

bool BP_RiskAllowsAdd(const ENUM_BP_MODE mode, const int openN, const int allowed, string &reason)
{
   if(mode == BP_MODE_LOCKDOWN) { reason = "LOCKDOWN"; return false; }
   if(allowed <= 0) { reason = "no entries allowed"; return false; }
   if(openN >= allowed) { reason = "at allowed entries"; return false; }
   if(openN >= BP_MAX_ENTRIES_HARD) { reason = "hard max 15"; return false; }
   if(mode == BP_MODE_DEFENSIVE && openN >= 1) { reason = "DEFENSIVE no-add"; return false; }
   return true;
}

//======================================================================
// ENGINE 6: SAME-PRICE BURST ENTRY
//======================================================================
bool BP_PriceInSameBand(const double refPrice, const ENUM_ORDER_TYPE type)
{
   if(refPrice <= 0.0) return true;
   const double px = (type == ORDER_TYPE_BUY ? SymbolInfoDouble(g_symbol, SYMBOL_ASK)
                                            : SymbolInfoDouble(g_symbol, SYMBOL_BID));
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

   if(bias == BP_BIAS_BUY)
      return trade.Buy(lot, g_symbol, ask, BP_NormPrice(ask - dist), 0.0, "BP-BUY");
   return trade.Sell(lot, g_symbol, bid, BP_NormPrice(bid + dist), 0.0, "BP-SELL");
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
   g_mode = BP_RiskMode(sig, BP_FloatingProfit());
   const int allowed = BP_AllowedEntries(g_mode, sig);
   if(!BP_RiskAllowsAdd(g_mode, openN, allowed, reason))
   {
      BP_Log("Risk block: " + reason + " (" + BP_ModeName(g_mode) + ")");
      return false;
   }

   ENUM_BP_BIAS bias = g_bias;
   if(bias == BP_BIAS_NONE) bias = sig.bias;
   if(bias == BP_BIAS_NONE) return false;

   const ENUM_BP_BIAS openBias = BP_OpenBias();
   if(openBias != BP_BIAS_NONE && openBias != bias)
      return false;

   const ENUM_ORDER_TYPE otype = (bias == BP_BIAS_BUY ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   const double price = (bias == BP_BIAS_BUY ? SymbolInfoDouble(g_symbol, SYMBOL_ASK)
                                             : SymbolInfoDouble(g_symbol, SYMBOL_BID));

   double ref = g_first_fill_price;
   if(ref <= 0.0 && openN > 0) ref = BP_FirstOpenPrice();
   if(!BP_PriceInSameBand(ref, otype))
   {
      BP_Log("Skip add: outside same-price band");
      return false;
   }

   const ulong nowMs = BP_NowMs();
   if(g_last_burst_ms > 0 && (nowMs - g_last_burst_ms) < (ulong)BP_BURST_GAP_MS)
      return false;
   if(openN > 0 && g_burst_count >= BP_MAX_BURST_PULSE)
      return false;

   const double lot = BP_CalcLot(otype, price, g_mode);
   if(lot <= 0.0) return false;

   if(!BP_OpenMarket(bias, lot))
   {
      BP_Log("Entry fail ret=" + IntegerToString(trade.ResultRetcode()));
      return false;
   }

   if(g_cycle_lot <= 0.0) g_cycle_lot = lot;
   if(g_first_fill_price <= 0.0) g_first_fill_price = price;
   g_burst_count++;
   g_last_burst_ms = nowMs;
   g_bias = bias;
   g_state = BP_MANAGE;

   BP_Log("ENTER " + (bias == BP_BIAS_BUY ? "BUY" : "SELL") +
          " lot=" + DoubleToString(lot, 2) +
          " mode=" + BP_ModeName(g_mode) +
          " str=" + DoubleToString(sig.strength, 2) +
          " open=" + IntegerToString(openN + 1) + "/" + IntegerToString(allowed));
   return true;
}

//======================================================================
// ENGINE 7: SMART SELF-EXIT BRAIN
//======================================================================
bool BP_ShouldThreatClose(const ENUM_BP_BIAS openBias, const AdaptiveSignal &sig, const double pnl)
{
   if(openBias == BP_BIAS_NONE) return false;

   const double minSecure = BP_MinSecureMoney();
   if(pnl > g_peak_profit) g_peak_profit = pnl;

   bool oppositeImb = false;
   if(sig.valid)
   {
      if(openBias == BP_BIAS_BUY)
         oppositeImb = (sig.downBias >= 0.58 && sig.netMove < 0.0);
      else
         oppositeImb = (sig.upBias >= 0.58 && sig.netMove > 0.0);
   }

   const bool candleThreat = BP_CandleThreat(openBias);
   const bool hadProfit = (g_peak_profit >= minSecure);
   const bool giveback = (hadProfit && pnl <= g_peak_profit * 0.55);
   const bool flipRisk = (hadProfit && pnl < minSecure * 0.35 && (oppositeImb || candleThreat));

   if(hadProfit && oppositeImb && candleThreat) return true;
   if(hadProfit && giveback && (oppositeImb || candleThreat)) return true;
   if(flipRisk) return true;
   if(g_mode == BP_MODE_LOCKDOWN && pnl < 0.0 && oppositeImb) return true;
   return false;
}

//======================================================================
// STATE MACHINE (architecture flow)
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
   const ENUM_BP_BIAS openBias = BP_OpenBias();
   if(openBias != BP_BIAS_NONE) g_bias = openBias;

   const double pnl = BP_FloatingProfit();
   g_mode = BP_RiskMode(sig, pnl);

   // Exit brain first
   string newsReason;
   const bool newsBlock = BP_NewsBlocked(newsReason);
   if(BP_ShouldThreatClose(openBias, sig, pnl))
   {
      if(BP_CloseAll("threat-close pnl=" + DoubleToString(pnl, 2)))
      {
         BP_MemoryAdd(pnl);
         BP_EnterCooldown("threat-close");
      }
      return;
   }

   // Protect green during news landmine
   if(newsBlock && pnl >= BP_MinSecureMoney() &&
      (BP_CandleThreat(openBias) ||
       (sig.valid && openBias == BP_BIAS_BUY && sig.downBias > 0.55) ||
       (sig.valid && openBias == BP_BIAS_SELL && sig.upBias > 0.55)))
   {
      if(BP_CloseAll("news-protect " + newsReason))
      {
         BP_MemoryAdd(pnl);
         BP_EnterCooldown("news-protect");
      }
      return;
   }

   // Add only into strength, same price, Risk Manager approved
   if(g_mode == BP_MODE_LOCKDOWN || g_mode == BP_MODE_DEFENSIVE)
      return;

   string reason;
   if(!BP_CanOpenNewEntries(reason))
      return;

   if(sig.valid && sig.bias == openBias && BP_CandleAgrees(openBias) && sig.strength >= 0.45)
   {
      g_state = BP_ENTER_BURST;
      BP_TryBurstEntry(sig);
   }
}

void BP_ProcessSetup(const AdaptiveSignal &sig)
{
   if(g_setup_time > 0 && TimeCurrent() - g_setup_time > BP_SETUP_EXPIRE_SEC)
   {
      BP_ResetSetup();
      g_state = BP_IDLE;
      return;
   }
   if(!sig.valid) return;

   // IDLE / BIAS_DETECT -> need tick imbalance + candle agree
   if(g_state == BP_IDLE || g_state == BP_BIAS_DETECT)
   {
      if(sig.bias != BP_BIAS_NONE && BP_CandleAgrees(sig.bias) && sig.strength >= 0.35)
      {
         g_bias = sig.bias;
         g_setup_time = TimeCurrent();
         g_impulse_move = MathAbs(sig.netMove);
         g_impulse_extreme = BP_Mid();
         g_pullback_seen = false;
         g_pullback_extreme = g_impulse_extreme;
         g_burst_count = 0;
         g_state = BP_IMPULSE_CONFIRM;
         BP_Log("Impulse " + (g_bias == BP_BIAS_BUY ? "BUY" : "SELL") +
                " imb=" + DoubleToString(MathMax(sig.upBias, sig.downBias), 2) +
                " win=" + IntegerToString(sig.windowSec) + "s" +
                " str=" + DoubleToString(sig.strength, 2));
      }
      else g_state = BP_BIAS_DETECT;
      return;
   }

   // IMPULSE_CONFIRM -> wait until impulse established, then pullback
   if(g_state == BP_IMPULSE_CONFIRM)
   {
      if(sig.bias != BP_BIAS_NONE && sig.bias != g_bias)
      {
         BP_ResetSetup();
         g_state = BP_IDLE;
         return;
      }

      const double mid = BP_Mid();
      if(g_bias == BP_BIAS_BUY && mid > g_impulse_extreme) g_impulse_extreme = mid;
      if(g_bias == BP_BIAS_SELL && (g_impulse_extreme <= 0.0 || mid < g_impulse_extreme)) g_impulse_extreme = mid;
      g_impulse_move = MathMax(g_impulse_move, MathAbs(sig.netMove));

      if(g_impulse_move >= BP_Unit() * 0.25)
      {
         g_state = BP_WAIT_PULLBACK;
         g_pullback_extreme = mid;
      }
      return;
   }

   // WAIT_PULLBACK -> architecture: small pullback then resume
   if(g_state == BP_WAIT_PULLBACK)
   {
      const double mid = BP_Mid();
      if(g_bias == BP_BIAS_BUY)
      {
         if(mid > g_impulse_extreme) g_impulse_extreme = mid;
         if(!g_pullback_seen || mid < g_pullback_extreme) g_pullback_extreme = mid;

         const double depth = (g_impulse_move > 0.0 ? (g_impulse_extreme - mid) / g_impulse_move : 0.0);
         if(depth >= 0.85)
         {
            BP_Log("Setup cancel: pullback too deep");
            BP_ResetSetup();
            g_state = BP_IDLE;
            return;
         }
         if(depth >= 0.22) g_pullback_seen = true;

         if(g_pullback_seen && sig.bias == BP_BIAS_BUY &&
            mid > g_pullback_extreme + 2.0 * BP_Point() &&
            BP_CandleAgrees(BP_BIAS_BUY))
            g_state = BP_ENTER_BURST;
      }
      else if(g_bias == BP_BIAS_SELL)
      {
         if(mid < g_impulse_extreme) g_impulse_extreme = mid;
         if(!g_pullback_seen || mid > g_pullback_extreme) g_pullback_extreme = mid;

         const double depth = (g_impulse_move > 0.0 ? (mid - g_impulse_extreme) / g_impulse_move : 0.0);
         if(depth >= 0.85)
         {
            BP_Log("Setup cancel: pullback too deep");
            BP_ResetSetup();
            g_state = BP_IDLE;
            return;
         }
         if(depth >= 0.22) g_pullback_seen = true;

         if(g_pullback_seen && sig.bias == BP_BIAS_SELL &&
            mid < g_pullback_extreme - 2.0 * BP_Point() &&
            BP_CandleAgrees(BP_BIAS_SELL))
            g_state = BP_ENTER_BURST;
      }
      return;
   }

   // ENTER_BURST -> same-price burst under Risk Manager
   if(g_state == BP_ENTER_BURST)
   {
      if(sig.bias != BP_BIAS_NONE && sig.bias != g_bias)
      {
         if(BP_CountPositions() > 0) g_state = BP_MANAGE;
         else { BP_ResetSetup(); g_state = BP_IDLE; }
         return;
      }

      BP_TryBurstEntry(sig);

      if(BP_CountPositions() > 0)
      {
         const int openN = BP_CountPositions();
         const int allowed = BP_AllowedEntries(g_mode, sig);
         if(openN >= allowed || g_burst_count >= BP_MAX_BURST_PULSE)
            g_state = BP_MANAGE;
      }
   }
}

void BP_OnTickState()
{
   // Always-on: ingest ticks every tick
   BP_PushTick();

   if(BP_CountPositions() > 0)
   {
      g_state = BP_MANAGE;
      BP_ManageOpen();
      return;
   }

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
// MEMORY FROM CLOSED DEALS
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

   BP_Log("Architecture v2.00 locked | symbol=" + g_symbol +
          " | family=" + (g_is_gold ? "XAUUSD" : "US30") +
          " | maxEntries=15 | session=NY-London | news=USD-high+FOMC | pullback=ON | no-martingale");
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   BP_Log("Deinit reason=" + IntegerToString(reason) + " mode=" + BP_ModeName(g_mode));
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
   if(trans.deal == 0) return;
   if(!HistoryDealSelect(trans.deal))
   {
      HistorySelect(TimeCurrent() - 86400, TimeCurrent() + 60);
      if(!HistoryDealSelect(trans.deal)) return;
   }
   BP_TrackHistoryDeal(trans.deal);
}

//+------------------------------------------------------------------+
