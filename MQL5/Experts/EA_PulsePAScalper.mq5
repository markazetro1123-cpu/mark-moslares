//+------------------------------------------------------------------+
//| EA_PulsePAScalper.mq5                                            |
//| Pure Price-Action Scalper — NO indicators                        |
//| Micro-range break + impulse candle confirmation                  |
//+------------------------------------------------------------------+
#property copyright "Mark Moslares"
#property link      "https://github.com/markazetro1123-cpu/mark-moslares"
#property version   "1.01"
#property description "M1-tuned pure price-action scalper (no indicators). Attach on M1."
#property strict

#include <Trade/Trade.mqh>

//======================================================================
// Inputs — defaults tuned for M1 + NY session (broker server time)
//======================================================================
input group "=== Strategy (price action only) ==="
input int    InpRangeBars           = 6;       // Micro-range lookback (M1 ≈ 6 min)
input double InpMinBodyRatio        = 0.50;    // Min body / candle range (impulse quality)
input double InpMinCandlePoints     = 50;      // Min signal candle size (points) — raise for XAU/US30 if noisy
input double InpBreakBufferPoints   = 3;       // Extra break beyond range (points)
input bool   InpRequireCloseNearExt = true;    // Close must be in outer 35% of candle
input bool   InpAllowBuy            = true;    // Allow BUY breakouts
input bool   InpAllowSell           = true;    // Allow SELL breakouts

input group "=== Session (broker server time) ==="
input bool   InpUseSessionFilter    = true;    // Enable session window
input int    InpSessionStartHour    = 15;      // NY open ~15:00 on GMT+2/3 brokers
input int    InpSessionStartMin     = 0;       // Start minute
input int    InpSessionEndHour      = 23;      // NY afternoon / late session end
input int    InpSessionEndMin       = 0;       // End minute

input group "=== Exits ==="
input double InpSLBufferPoints      = 25;      // SL buffer beyond structure (points)
input double InpRiskReward          = 1.2;     // Scalp R:R (faster TP on M1)
input bool   InpUseBreakEven        = true;    // Move SL to BE after +BE trigger
input double InpBETriggerRR         = 0.7;     // BE trigger as fraction of SL distance
input double InpBELockPoints        = 5;       // Lock profit at BE (points)
input bool   InpUseTimeExit         = true;    // Force close after max hold
input int    InpMaxHoldSeconds      = 480;     // Max hold (8 min) — keep M1 trades short

input group "=== Filters / frequency ==="
input double InpMaxSpreadPoints     = 40;      // Max spread (points), 0 = off
input int    InpCooldownSeconds     = 20;      // Short cooldown so M1 can re-fire
input int    InpMaxTradesPerDay     = 50;      // Hard cap for active M1 day
input long   InpMagic               = 26072601;// Magic number

input group "=== Risk ==="
input double InpRiskPercent         = 0.4;     // Risk % per trade (lower because more entries)
input double InpFixedLot            = 0.0;     // Fixed lot (0 = use risk %)
input double InpMaxDailyLossPct     = 3.0;     // Pause day after this equity drawdown %
input int    InpSlippagePoints      = 40;      // Max slippage (points)

//======================================================================
// Globals
//======================================================================
CTrade   g_trade;
string   g_symbol;
ENUM_TIMEFRAMES g_tf;
datetime g_lastBarTime      = 0;
datetime g_cooldownUntil    = 0;
datetime g_dayStamp         = 0;
double   g_dayStartEquity   = 0.0;
bool     g_dailyLocked      = false;
int      g_tradesToday      = 0;
ulong    g_managedTicket    = 0;
bool     g_beMoved          = false;

//======================================================================
// Utils
//======================================================================
double PAS_Point()
{
   double p = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   return (p > 0.0 ? p : _Point);
}

int PAS_Digits()
{
   return (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
}

double PAS_NormPrice(const double price)
{
   return NormalizeDouble(price, PAS_Digits());
}

double PAS_NormVol(double volume)
{
   const double vmin  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   const double vmax  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   const double vstep = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   if(vstep <= 0.0)
      return vmin;
   volume = MathFloor(volume / vstep + 1e-12) * vstep;
   volume = MathMax(vmin, MathMin(vmax, volume));
   int volDigits = 2;
   if(vstep < 0.01) volDigits = 3;
   if(vstep >= 1.0) volDigits = 0;
   return NormalizeDouble(volume, volDigits);
}

bool PAS_SelectFilling(ENUM_ORDER_TYPE_FILLING &filling)
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

double PAS_SpreadPoints()
{
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   return MathMax(0.0, ask - bid) / PAS_Point();
}

bool PAS_TradeAllowed()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;
   if((ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
      return false;
   return true;
}

bool PAS_SpreadOk()
{
   if(InpMaxSpreadPoints <= 0.0)
      return true;
   return (PAS_SpreadPoints() <= InpMaxSpreadPoints);
}

bool PAS_InSession()
{
   if(!InpUseSessionFilter)
      return true;

   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   const int nowMin = dt.hour * 60 + dt.min;
   const int start  = InpSessionStartHour * 60 + InpSessionStartMin;
   const int endt   = InpSessionEndHour * 60 + InpSessionEndMin;

   if(start == endt)
      return true; // 24h
   if(start < endt)
      return (nowMin >= start && nowMin < endt);
   // overnight window
   return (nowMin >= start || nowMin < endt);
}

void PAS_ResetDayIfNeeded()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   const datetime dayKey = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));
   if(dayKey != g_dayStamp)
   {
      g_dayStamp = dayKey;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_dailyLocked = false;
      g_tradesToday = 0;
   }

   if(InpMaxDailyLossPct <= 0.0 || g_dayStartEquity <= 0.0)
      return;

   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   const double ddPct = ((g_dayStartEquity - eq) / g_dayStartEquity) * 100.0;
   if(ddPct >= InpMaxDailyLossPct)
   {
      if(!g_dailyLocked)
         PrintFormat("PulsePA: daily loss lock hit (%.2f%%). Pausing new entries.", ddPct);
      g_dailyLocked = true;
   }
}

bool PAS_HasOurPosition(ulong &ticket, long &type, double &openPrice, datetime &openTime)
{
   ticket = 0;
   type = -1;
   openPrice = 0.0;
   openTime = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;
      ticket = t;
      type = (long)PositionGetInteger(POSITION_TYPE);
      openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      openTime = (datetime)PositionGetInteger(POSITION_TIME);
      return true;
   }
   return false;
}

double PAS_CalcLot(const double slDistancePrice)
{
   if(InpFixedLot > 0.0)
      return PAS_NormVol(InpFixedLot);

   if(slDistancePrice <= 0.0 || InpRiskPercent <= 0.0)
      return PAS_NormVol(SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN));

   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   const double riskMoney = equity * (InpRiskPercent / 100.0);
   const double tickSize = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_SIZE);
   const double tickValue = SymbolInfoDouble(g_symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0)
      return PAS_NormVol(SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN));

   const double lossPerLot = (slDistancePrice / tickSize) * tickValue;
   if(lossPerLot <= 0.0)
      return PAS_NormVol(SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN));

   return PAS_NormVol(riskMoney / lossPerLot);
}

//======================================================================
// Signal — pure OHLC, no indicators
//======================================================================
enum ENUM_PAS_SIGNAL
{
   PAS_NONE = 0,
   PAS_BUY  = 1,
   PAS_SELL = -1
};

bool PAS_CandleQuality(const int shift, const bool bullish)
{
   const double o = iOpen(g_symbol, g_tf, shift);
   const double h = iHigh(g_symbol, g_tf, shift);
   const double l = iLow(g_symbol, g_tf, shift);
   const double c = iClose(g_symbol, g_tf, shift);
   const double range = h - l;
   const double point = PAS_Point();

   if(range < InpMinCandlePoints * point)
      return false;

   const double body = MathAbs(c - o);
   if(range <= 0.0 || (body / range) < InpMinBodyRatio)
      return false;

   // Direction must match candle color
   if(bullish && !(c > o))
      return false;
   if(!bullish && !(c < o))
      return false;

   if(InpRequireCloseNearExt)
   {
      // Close in outer 35% toward break direction
      if(bullish)
      {
         const double threshold = h - range * 0.35;
         if(c < threshold)
            return false;
      }
      else
      {
         const double threshold = l + range * 0.35;
         if(c > threshold)
            return false;
      }
   }
   return true;
}

ENUM_PAS_SIGNAL PAS_DetectSignal(double &slPrice, double &tpPrice)
{
   slPrice = 0.0;
   tpPrice = 0.0;

   const int need = InpRangeBars + 2;
   if(Bars(g_symbol, g_tf) < need)
      return PAS_NONE;
   if(InpRangeBars < 2)
      return PAS_NONE;

   // Micro-range from closed bars 2..(1+RangeBars) — bar 1 is signal candidate
   double rangeHigh = -DBL_MAX;
   double rangeLow  = DBL_MAX;
   for(int i = 2; i <= InpRangeBars + 1; ++i)
   {
      rangeHigh = MathMax(rangeHigh, iHigh(g_symbol, g_tf, i));
      rangeLow  = MathMin(rangeLow,  iLow(g_symbol, g_tf, i));
   }
   if(rangeHigh <= rangeLow)
      return PAS_NONE;

   const double point  = PAS_Point();
   const double buffer = InpBreakBufferPoints * point;
   const double sigH   = iHigh(g_symbol, g_tf, 1);
   const double sigL   = iLow(g_symbol, g_tf, 1);
   const double sigC   = iClose(g_symbol, g_tf, 1);
   const double ask    = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double bid    = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double slBuf  = InpSLBufferPoints * point;
   const double rr     = MathMax(0.5, InpRiskReward);

   // BUY: close breaks above micro-range high with impulse quality
   if(InpAllowBuy &&
      sigC > (rangeHigh + buffer) &&
      PAS_CandleQuality(1, true))
   {
      slPrice = PAS_NormPrice(MathMin(rangeLow, sigL) - slBuf);
      const double entry = ask;
      const double slDist = entry - slPrice;
      if(slDist <= 0.0)
         return PAS_NONE;
      // TP must beat spread noise
      if(slDist * rr <= PAS_SpreadPoints() * point)
         return PAS_NONE;
      tpPrice = PAS_NormPrice(entry + slDist * rr);
      return PAS_BUY;
   }

   // SELL: close breaks below micro-range low with impulse quality
   if(InpAllowSell &&
      sigC < (rangeLow - buffer) &&
      PAS_CandleQuality(1, false))
   {
      slPrice = PAS_NormPrice(MathMax(rangeHigh, sigH) + slBuf);
      const double entry = bid;
      const double slDist = slPrice - entry;
      if(slDist <= 0.0)
         return PAS_NONE;
      if(slDist * rr <= PAS_SpreadPoints() * point)
         return PAS_NONE;
      tpPrice = PAS_NormPrice(entry - slDist * rr);
      return PAS_SELL;
   }

   return PAS_NONE;
}

//======================================================================
// Trade management
//======================================================================
void PAS_ManageOpen(const ulong ticket, const long type, const double openPrice, const datetime openTime)
{
   if(!PositionSelectByTicket(ticket))
      return;

   const double sl = PositionGetDouble(POSITION_SL);
   const double tp = PositionGetDouble(POSITION_TP);
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double point = PAS_Point();

   // Time exit for scalps
   if(InpUseTimeExit && InpMaxHoldSeconds > 0)
   {
      if(TimeCurrent() - openTime >= InpMaxHoldSeconds)
      {
         if(g_trade.PositionClose(ticket))
         {
            Print("PulsePA: time-exit closed #", ticket);
            g_cooldownUntil = TimeCurrent() + InpCooldownSeconds;
            g_managedTicket = 0;
            g_beMoved = false;
         }
         return;
      }
   }

   if(!InpUseBreakEven || g_beMoved)
      return;

   const double beTrig = InpBETriggerRR;
   const double lock   = InpBELockPoints * point;

   if(type == POSITION_TYPE_BUY)
   {
      const double risk = (sl > 0.0 ? (openPrice - sl) : 0.0);
      if(risk <= 0.0)
         return;
      if(bid >= openPrice + risk * beTrig)
      {
         const double newSL = PAS_NormPrice(openPrice + lock);
         if(newSL > sl || sl == 0.0)
         {
            if(g_trade.PositionModify(ticket, newSL, tp))
            {
               g_beMoved = true;
               PrintFormat("PulsePA: BUY BE lock @ %.5f", newSL);
            }
         }
      }
   }
   else if(type == POSITION_TYPE_SELL)
   {
      const double risk = (sl > 0.0 ? (sl - openPrice) : 0.0);
      if(risk <= 0.0)
         return;
      if(ask <= openPrice - risk * beTrig)
      {
         const double newSL = PAS_NormPrice(openPrice - lock);
         if(newSL < sl || sl == 0.0)
         {
            if(g_trade.PositionModify(ticket, newSL, tp))
            {
               g_beMoved = true;
               PrintFormat("PulsePA: SELL BE lock @ %.5f", newSL);
            }
         }
      }
   }
}

bool PAS_OpenTrade(const ENUM_PAS_SIGNAL sig, const double slPrice, const double tpPrice)
{
   ENUM_ORDER_TYPE_FILLING filling;
   PAS_SelectFilling(filling);
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFilling(filling);

   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double slDist = 0.0;
   bool ok = false;

   if(sig == PAS_BUY)
   {
      slDist = ask - slPrice;
      const double lots = PAS_CalcLot(slDist);
      ok = g_trade.Buy(lots, g_symbol, ask, slPrice, tpPrice, "PulsePA BUY");
   }
   else if(sig == PAS_SELL)
   {
      slDist = slPrice - bid;
      const double lots = PAS_CalcLot(slDist);
      ok = g_trade.Sell(lots, g_symbol, bid, slPrice, tpPrice, "PulsePA SELL");
   }

   if(ok)
   {
      g_tradesToday++;
      g_beMoved = false;
      g_managedTicket = g_trade.ResultOrder();
      PrintFormat("PulsePA: opened %s sl=%.5f tp=%.5f tradesToday=%d",
                  (sig == PAS_BUY ? "BUY" : "SELL"), slPrice, tpPrice, g_tradesToday);
   }
   else
   {
      PrintFormat("PulsePA: order failed retcode=%u %s",
                  g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
   }
   return ok;
}

//======================================================================
// Lifecycle
//======================================================================
int OnInit()
{
   g_symbol = _Symbol;
   g_tf = (ENUM_TIMEFRAMES)_Period;

   ENUM_ORDER_TYPE_FILLING filling;
   PAS_SelectFilling(filling);
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFilling(filling);

   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   g_dayStamp = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));

   if(g_tf != PERIOD_M1)
      PrintFormat("PulsePA WARNING: defaults are tuned for M1, chart is %s. Attach on M1 for intended behavior.",
                  EnumToString(g_tf));

   PrintFormat("PulsePA v1.01 M1 | %s %s | range=%d body>=%.0f%% minPts=%.0f RR=%.2f risk=%.2f%% session=%02d:%02d-%02d:%02d",
               g_symbol, EnumToString(g_tf), InpRangeBars, InpMinBodyRatio * 100.0,
               InpMinCandlePoints, InpRiskReward, InpRiskPercent,
               InpSessionStartHour, InpSessionStartMin, InpSessionEndHour, InpSessionEndMin);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
}

void OnTick()
{
   PAS_ResetDayIfNeeded();

   ulong ticket;
   long type;
   double openPrice;
   datetime openTime;
   const bool hasPos = PAS_HasOurPosition(ticket, type, openPrice, openTime);

   if(hasPos)
   {
      if(g_managedTicket != ticket)
      {
         g_managedTicket = ticket;
         g_beMoved = false;
      }
      PAS_ManageOpen(ticket, type, openPrice, openTime);
      return;
   }

   // Detect just-closed position → cooldown
   if(g_managedTicket != 0)
   {
      g_cooldownUntil = TimeCurrent() + InpCooldownSeconds;
      g_managedTicket = 0;
      g_beMoved = false;
   }

   if(g_dailyLocked)
      return;
   if(!PAS_InSession())
      return;
   if(!PAS_TradeAllowed())
      return;
   if(!PAS_SpreadOk())
      return;
   if(g_cooldownUntil > 0 && TimeCurrent() < g_cooldownUntil)
      return;
   if(InpMaxTradesPerDay > 0 && g_tradesToday >= InpMaxTradesPerDay)
      return;

   // New closed bar only — avoids spam / repaint
   const datetime barTime = iTime(g_symbol, g_tf, 0);
   if(barTime == 0 || barTime == g_lastBarTime)
      return;
   g_lastBarTime = barTime;

   double slPrice = 0.0, tpPrice = 0.0;
   const ENUM_PAS_SIGNAL sig = PAS_DetectSignal(slPrice, tpPrice);
   if(sig == PAS_NONE)
      return;

   PAS_OpenTrade(sig, slPrice, tpPrice);
}
//+------------------------------------------------------------------+
