//+------------------------------------------------------------------+
//|                                       PovertyScalperClone.mq5     |
//|                                                                  |
//|  Educational M1 scalping Expert Advisor that replicates the      |
//|  publicly described "Poverty Scalper Robot" style circulated on  |
//|  TikTok / Telegram:                                              |
//|    - M1 (1 minute) scalping on major FX pairs / XAUUSD / indices |
//|    - Momentum + trend entries (EMA cross + RSI + candle body)    |
//|    - Fixed Take Profit / Stop Loss on every trade               |
//|    - Spread filter, trading-session filter                       |
//|    - Optional trailing stop                                      |
//|    - Max equity drawdown guard                                   |
//|    - On-chart live stats panel                                   |
//|                                                                  |
//|  NOTE: This is a transparent re-implementation for study and     |
//|  demo/backtesting. It deliberately does NOT use hidden           |
//|  martingale / grid recovery. Test on DEMO first.                 |
//+------------------------------------------------------------------+
#property copyright "Educational clone - for study & backtesting only"
#property link      "https://github.com/markazetro1123-cpu/mark-moslares"
#property version   "1.00"
#property description "M1 momentum scalper inspired by the 'Poverty Scalper Robot' style. DEMO first."
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/SymbolInfo.mqh>

//====================================================================
//  INPUTS
//====================================================================
input group "=== General ==="
input ulong   InpMagic            = 20260725;   // Magic number (unique per chart)
input double  InpLots             = 0.01;       // Fixed lot size
input int     InpMaxPositions     = 1;          // Max simultaneous positions (this symbol)
input int     InpMaxSpreadPoints  = 20;         // Max allowed spread in points (0 = ignore)
input int     InpSlippagePoints   = 10;         // Max deviation/slippage (points)

input group "=== Targets (in points) — tight scalper defaults ==="
input int     InpTakeProfitPts    = 30;         // Take Profit (points)
input int     InpStopLossPts      = 30;         // Stop Loss (points)
input bool    InpUseTrailing      = true;       // Enable trailing stop
input int     InpTrailStartPts    = 15;         // Trailing: profit needed to arm (points)
input int     InpTrailStepPts     = 10;         // Trailing: trail distance (points)

input group "=== Entry (momentum + trend) ==="
input int     InpEmaFast          = 8;          // Fast EMA period
input int     InpEmaSlow          = 21;         // Slow EMA period
input int     InpRsiPeriod        = 14;         // RSI period
input double  InpRsiBuyLevel      = 55.0;       // RSI must be >= this for BUY
input double  InpRsiSellLevel     = 45.0;       // RSI must be <= this for SELL
input int     InpMomentumBodyPts  = 30;         // Min body size of last candle (points)

input group "=== Session filter (broker/server time) ==="
// Default window ~ London/NY OVERLAP (approx 12:00-16:00 UTC).
// Hours are BROKER/SERVER time — adjust to your broker's GMT offset!
input bool    InpUseSession       = true;       // Restrict trading to a session window
input int     InpSessionStartHour = 13;         // Start hour (0-23, server time)
input int     InpSessionEndHour   = 17;         // End hour (0-23, server time)
input bool    InpTradeFriday      = true;       // Allow trading on Fridays
input int     InpFridayStopHour   = 20;         // Stop opening trades on Friday after this hour

input group "=== Risk guard ==="
input double  InpMaxDrawdownPct   = 20.0;       // Max equity drawdown % from peak (0 = off)
input bool    InpCloseAllOnHalt   = false;      // Close open trades when drawdown guard trips

input group "=== Display ==="
input bool    InpShowPanel        = true;       // Show on-chart stats panel

//====================================================================
//  GLOBALS
//====================================================================
CTrade         trade;
CPositionInfo  posinfo;
CSymbolInfo    syminfo;

int      g_hEmaFast = INVALID_HANDLE;
int      g_hEmaSlow = INVALID_HANDLE;
int      g_hRsi     = INVALID_HANDLE;

double   g_equityPeak = 0.0;
bool     g_halted     = false;
datetime g_lastBarTime = 0;

//====================================================================
//  INIT / DEINIT
//====================================================================
int OnInit()
{
   if(!syminfo.Name(_Symbol))
   {
      Print("Failed to init symbol info");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints((ulong)InpSlippagePoints);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   g_hEmaFast = iMA(_Symbol, PERIOD_M1, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE);
   g_hEmaSlow = iMA(_Symbol, PERIOD_M1, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE);
   g_hRsi     = iRSI(_Symbol, PERIOD_M1, InpRsiPeriod, PRICE_CLOSE);

   if(g_hEmaFast == INVALID_HANDLE || g_hEmaSlow == INVALID_HANDLE || g_hRsi == INVALID_HANDLE)
   {
      Print("Failed to create indicator handles");
      return(INIT_FAILED);
   }

   g_equityPeak = AccountInfoDouble(ACCOUNT_EQUITY);
   g_halted     = false;

   Print("PovertyScalperClone initialized on ", _Symbol,
         " | point=", _Point, " digits=", _Digits);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   if(g_hEmaFast != INVALID_HANDLE) IndicatorRelease(g_hEmaFast);
   if(g_hEmaSlow != INVALID_HANDLE) IndicatorRelease(g_hEmaSlow);
   if(g_hRsi     != INVALID_HANDLE) IndicatorRelease(g_hRsi);
   Comment("");
}

//====================================================================
//  MAIN TICK
//====================================================================
void OnTick()
{
   syminfo.RefreshRates();

   // Trailing runs every tick so exits stay responsive.
   if(InpUseTrailing)
      ManageTrailing();

   // Risk guard evaluated every tick.
   UpdateRiskGuard();

   if(InpShowPanel)
      DrawPanel();

   // Entry logic only on a new M1 bar.
   if(!IsNewBar())
      return;

   if(g_halted)
      return;

   if(!SessionAllowsTrading())
      return;

   if(!SpreadOk())
      return;

   if(CountPositions() >= InpMaxPositions)
      return;

   int signal = GetSignal(); // +1 buy, -1 sell, 0 none
   if(signal > 0)
      OpenTrade(ORDER_TYPE_BUY);
   else if(signal < 0)
      OpenTrade(ORDER_TYPE_SELL);
}

//====================================================================
//  SIGNAL
//====================================================================
//  Momentum + trend confirmation on the last closed M1 candle:
//   BUY  : fast EMA above slow EMA, RSI >= buy level,
//          last candle bullish with body >= threshold.
//   SELL : mirror image.
//====================================================================
int GetSignal()
{
   // Read the values of the last CLOSED M1 bar (shift 1).
   // Single-element copies from start_pos=1 avoid as-series ambiguity.
   double emaFast[1], emaSlow[1], rsi[1];

   if(CopyBuffer(g_hEmaFast, 0, 1, 1, emaFast) < 1) return 0;
   if(CopyBuffer(g_hEmaSlow, 0, 1, 1, emaSlow) < 1) return 0;
   if(CopyBuffer(g_hRsi,     0, 1, 1, rsi)     < 1) return 0;

   double openPrev  = iOpen(_Symbol,  PERIOD_M1, 1);
   double closePrev = iClose(_Symbol, PERIOD_M1, 1);
   if(openPrev == 0.0 || closePrev == 0.0) return 0;

   double bodyPts = MathAbs(closePrev - openPrev) / _Point;
   if(bodyPts < InpMomentumBodyPts) return 0;

   bool bullTrend = emaFast[0] > emaSlow[0];
   bool bearTrend = emaFast[0] < emaSlow[0];

   bool bullCandle = closePrev > openPrev;
   bool bearCandle = closePrev < openPrev;

   if(bullTrend && bullCandle && rsi[0] >= InpRsiBuyLevel)
      return 1;

   if(bearTrend && bearCandle && rsi[0] <= InpRsiSellLevel)
      return -1;

   return 0;
}

//====================================================================
//  ORDER EXECUTION
//====================================================================
void OpenTrade(const ENUM_ORDER_TYPE type)
{
   double price = (type == ORDER_TYPE_BUY)
                  ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                  : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   price = NormalizeDouble(price, _Digits);

   // Respect the broker's minimum stop distance so tight SL/TP are not rejected.
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int slPts = InpStopLossPts;
   int tpPts = InpTakeProfitPts;
   if(slPts > 0 && slPts < stopsLevel + 1) slPts = stopsLevel + 1;
   if(tpPts > 0 && tpPts < stopsLevel + 1) tpPts = stopsLevel + 1;

   double sl = 0.0, tp = 0.0;
   if(type == ORDER_TYPE_BUY)
   {
      if(slPts > 0) sl = price - slPts * _Point;
      if(tpPts > 0) tp = price + tpPts * _Point;
   }
   else
   {
      if(slPts > 0) sl = price + slPts * _Point;
      if(tpPts > 0) tp = price - tpPts * _Point;
   }

   sl = (sl > 0) ? NormalizeDouble(sl, _Digits) : 0.0;
   tp = (tp > 0) ? NormalizeDouble(tp, _Digits) : 0.0;

   double lots = NormalizeLots(InpLots);

   bool ok = (type == ORDER_TYPE_BUY)
             ? trade.Buy(lots, _Symbol, price, sl, tp, "PovertyScalperClone")
             : trade.Sell(lots, _Symbol, price, sl, tp, "PovertyScalperClone");

   if(!ok)
      PrintFormat("Order failed: %s retcode=%d (%s)",
                  EnumToString(type), trade.ResultRetcode(),
                  trade.ResultRetcodeDescription());
}

//====================================================================
//  TRAILING STOP
//====================================================================
void ManageTrailing()
{
   int stopsLevel = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int trailStep  = InpTrailStepPts;
   if(trailStep < stopsLevel + 1) trailStep = stopsLevel + 1;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posinfo.SelectByIndex(i)) continue;
      if(posinfo.Symbol() != _Symbol) continue;
      if(posinfo.Magic()  != (long)InpMagic) continue;

      double openPrice = posinfo.PriceOpen();
      double curSL     = posinfo.StopLoss();
      double tp        = posinfo.TakeProfit();
      long   type      = posinfo.PositionType();

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if(type == POSITION_TYPE_BUY)
      {
         double profitPts = (bid - openPrice) / _Point;
         if(profitPts >= InpTrailStartPts)
         {
            double newSL = NormalizeDouble(bid - trailStep * _Point, _Digits);
            if(newSL > openPrice && (curSL == 0.0 || newSL > curSL))
               trade.PositionModify(posinfo.Ticket(), newSL, tp);
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         double profitPts = (openPrice - ask) / _Point;
         if(profitPts >= InpTrailStartPts)
         {
            double newSL = NormalizeDouble(ask + trailStep * _Point, _Digits);
            if(newSL < openPrice && (curSL == 0.0 || newSL < curSL))
               trade.PositionModify(posinfo.Ticket(), newSL, tp);
         }
      }
   }
}

//====================================================================
//  RISK GUARD (max equity drawdown from peak)
//====================================================================
void UpdateRiskGuard()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity > g_equityPeak)
      g_equityPeak = equity;

   if(InpMaxDrawdownPct <= 0.0)
      return;

   double ddPct = (g_equityPeak > 0.0)
                  ? (g_equityPeak - equity) / g_equityPeak * 100.0
                  : 0.0;

   if(ddPct >= InpMaxDrawdownPct && !g_halted)
   {
      g_halted = true;
      PrintFormat("RISK GUARD tripped: drawdown %.2f%% >= %.2f%%. New trades halted.",
                  ddPct, InpMaxDrawdownPct);
      if(InpCloseAllOnHalt)
         CloseAllOwn();
   }
}

//====================================================================
//  HELPERS
//====================================================================
bool IsNewBar()
{
   datetime t = iTime(_Symbol, PERIOD_M1, 0);
   if(t != g_lastBarTime)
   {
      g_lastBarTime = t;
      return true;
   }
   return false;
}

bool SpreadOk()
{
   if(InpMaxSpreadPoints <= 0)
      return true;
   long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   return (spread <= InpMaxSpreadPoints);
}

bool SessionAllowsTrading()
{
   if(!InpUseSession)
      return true;

   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);

   if(now.day_of_week == 0 || now.day_of_week == 6) // Sun/Sat
      return false;

   if(now.day_of_week == 5) // Friday
   {
      if(!InpTradeFriday) return false;
      if(now.hour >= InpFridayStopHour) return false;
   }

   int h = now.hour;
   if(InpSessionStartHour <= InpSessionEndHour)
      return (h >= InpSessionStartHour && h < InpSessionEndHour);

   // Wrap-around window (e.g. 22 -> 6)
   return (h >= InpSessionStartHour || h < InpSessionEndHour);
}

int CountPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posinfo.SelectByIndex(i)) continue;
      if(posinfo.Symbol() == _Symbol && posinfo.Magic() == (long)InpMagic)
         count++;
   }
   return count;
}

void CloseAllOwn()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(!posinfo.SelectByIndex(i)) continue;
      if(posinfo.Symbol() != _Symbol) continue;
      if(posinfo.Magic()  != (long)InpMagic) continue;
      trade.PositionClose(posinfo.Ticket());
   }
}

double NormalizeLots(double lots)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(lotStep > 0.0)
      lots = MathFloor(lots / lotStep) * lotStep;
   if(lots < minLot) lots = minLot;
   if(lots > maxLot) lots = maxLot;
   return lots;
}

//====================================================================
//  ON-CHART PANEL
//====================================================================
void DrawPanel()
{
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double ddPct   = (g_equityPeak > 0.0)
                    ? (g_equityPeak - equity) / g_equityPeak * 100.0
                    : 0.0;
   long   spread  = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);

   string txt = StringFormat(
      "==== Poverty Scalper Clone ====\n"
      "Symbol   : %s  (M1)\n"
      "Balance  : %.2f\n"
      "Equity   : %.2f\n"
      "Peak eq. : %.2f\n"
      "Drawdown : %.2f%% (max %.1f%%)\n"
      "Spread   : %d pts (max %d)\n"
      "Open pos : %d / %d\n"
      "Session  : %s\n"
      "Status   : %s",
      _Symbol,
      balance, equity, g_equityPeak,
      ddPct, InpMaxDrawdownPct,
      (int)spread, InpMaxSpreadPoints,
      CountPositions(), InpMaxPositions,
      (SessionAllowsTrading() ? "OPEN" : "CLOSED"),
      (g_halted ? "HALTED (risk guard)" : "RUNNING"));

   Comment(txt);
}
//+------------------------------------------------------------------+
