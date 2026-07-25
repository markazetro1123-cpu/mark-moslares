//+------------------------------------------------------------------+
//| EA_TrendPulse.mq5                                                |
//| EMA crossover + RSI filter Expert Advisor for MetaTrader 5       |
//+------------------------------------------------------------------+
#property copyright "Mark Moslares"
#property link      "https://github.com/markazetro1123-cpu/mark-moslares"
#property version   "1.00"
#property description "TrendPulse EA: EMA crossover with RSI filter, ATR stops, and risk-based lots"
#property strict

#include <Trade/Trade.mqh>
#include <TradeHelpers.mqh>

//--- inputs: strategy
input group "=== Strategy ==="
input int      InpFastEMA        = 12;      // Fast EMA period
input int      InpSlowEMA        = 26;      // Slow EMA period
input int      InpRSIPeriod      = 14;      // RSI period
input double   InpRSIBuyMax      = 60.0;    // Max RSI for BUY (avoid overbought)
input double   InpRSISellMin     = 40.0;    // Min RSI for SELL (avoid oversold)
input ENUM_TIMEFRAMES InpTF      = PERIOD_CURRENT; // Signal timeframe

//--- inputs: risk
input group "=== Risk Management ==="
input double   InpRiskPercent    = 1.0;     // Risk % of balance per trade
input double   InpFixedLots      = 0.0;     // Fixed lots (0 = use risk %)
input double   InpATRMultiplier  = 1.5;     // SL distance = ATR * multiplier
input double   InpRRRatio        = 2.0;     // Take-profit = SL * RR
input int      InpATRPeriod      = 14;      // ATR period
input int      InpMaxPositions   = 1;       // Max open positions
input int      InpMagic          = 260725;  // Magic number

//--- inputs: filters
input group "=== Filters ==="
input double   InpMaxSpreadPts   = 30.0;    // Max spread (points)
input int      InpStartHour      = 0;       // Trade start hour (server)
input int      InpEndHour        = 24;      // Trade end hour (server, 24=same as 0)
input bool     InpTradeOnNewBar  = true;    // Signal only on new bar

//--- inputs: trailing
input group "=== Trailing Stop ==="
input bool     InpUseTrailing    = true;    // Enable trailing stop
input double   InpTrailPoints    = 200;     // Trail distance (points)
input double   InpTrailStepPts   = 20;      // Min step to move SL (points)

//--- globals
CTrade         g_trade;
int            g_emaFastHandle = INVALID_HANDLE;
int            g_emaSlowHandle = INVALID_HANDLE;
int            g_rsiHandle     = INVALID_HANDLE;
int            g_atrHandle     = INVALID_HANDLE;
datetime       g_lastBarTime   = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpFastEMA >= InpSlowEMA)
   {
      Print("ERROR: Fast EMA must be smaller than Slow EMA");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpRiskPercent <= 0.0 && InpFixedLots <= 0.0)
   {
      Print("ERROR: Set InpRiskPercent or InpFixedLots");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_emaFastHandle = iMA(_Symbol, InpTF, InpFastEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_emaSlowHandle = iMA(_Symbol, InpTF, InpSlowEMA, 0, MODE_EMA, PRICE_CLOSE);
   g_rsiHandle     = iRSI(_Symbol, InpTF, InpRSIPeriod, PRICE_CLOSE);
   g_atrHandle     = iATR(_Symbol, InpTF, InpATRPeriod);

   if(g_emaFastHandle == INVALID_HANDLE || g_emaSlowHandle == INVALID_HANDLE ||
      g_rsiHandle == INVALID_HANDLE || g_atrHandle == INVALID_HANDLE)
   {
      Print("ERROR: Failed to create indicator handles");
      return INIT_FAILED;
   }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(20);
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetAsyncMode(false);

   PrintFormat("TrendPulse EA initialized | %s | Magic=%d", _Symbol, InpMagic);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_emaFastHandle != INVALID_HANDLE) IndicatorRelease(g_emaFastHandle);
   if(g_emaSlowHandle != INVALID_HANDLE) IndicatorRelease(g_emaSlowHandle);
   if(g_rsiHandle != INVALID_HANDLE)     IndicatorRelease(g_rsiHandle);
   if(g_atrHandle != INVALID_HANDLE)     IndicatorRelease(g_atrHandle);
}

//+------------------------------------------------------------------+
void OnTick()
{
   if(InpUseTrailing)
      ApplyTrailingStop(g_trade, _Symbol, InpMagic, InpTrailPoints, InpTrailStepPts);

   if(InpTradeOnNewBar && !IsNewBar())
      return;

   if(!IsWithinTradingHours(InpStartHour, InpEndHour == 24 ? 0 : InpEndHour))
      return;

   if(CurrentSpreadPoints(_Symbol) > InpMaxSpreadPts)
      return;

   if(CountPositions(_Symbol, InpMagic) >= InpMaxPositions)
      return;

   int signal = GetSignal();
   if(signal == 0)
      return;

   double atr[];
   ArraySetAsSeries(atr, true);
   if(CopyBuffer(g_atrHandle, 0, 1, 1, atr) < 1 || atr[0] <= 0.0)
      return;

   const double stopDist = atr[0] * InpATRMultiplier;
   const double tpDist   = stopDist * InpRRRatio;
   const int    digits   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   const double ask      = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   const double bid      = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double lots = (InpFixedLots > 0.0)
                 ? NormalizeVolume(_Symbol, InpFixedLots)
                 : CalcLotByRisk(_Symbol, InpRiskPercent, stopDist);

   if(signal > 0)
   {
      const double sl = NormalizeDouble(ask - stopDist, digits);
      const double tp = NormalizeDouble(ask + tpDist, digits);
      if(!g_trade.Buy(lots, _Symbol, ask, sl, tp, "TrendPulse BUY"))
         PrintFormat("BUY failed: %s", g_trade.ResultRetcodeDescription());
      else
         PrintFormat("BUY opened | lots=%.2f SL=%.5f TP=%.5f", lots, sl, tp);
   }
   else
   {
      const double sl = NormalizeDouble(bid + stopDist, digits);
      const double tp = NormalizeDouble(bid - tpDist, digits);
      if(!g_trade.Sell(lots, _Symbol, bid, sl, tp, "TrendPulse SELL"))
         PrintFormat("SELL failed: %s", g_trade.ResultRetcodeDescription());
      else
         PrintFormat("SELL opened | lots=%.2f SL=%.5f TP=%.5f", lots, sl, tp);
   }
}

//+------------------------------------------------------------------+
//| +1 BUY, -1 SELL, 0 none                                          |
//+------------------------------------------------------------------+
int GetSignal()
{
   double fast[], slow[], rsi[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   ArraySetAsSeries(rsi, true);

   // Need bars 1 and 2 (closed bars) for crossover detection
   if(CopyBuffer(g_emaFastHandle, 0, 1, 3, fast) < 3) return 0;
   if(CopyBuffer(g_emaSlowHandle, 0, 1, 3, slow) < 3) return 0;
   if(CopyBuffer(g_rsiHandle, 0, 1, 2, rsi) < 2)       return 0;

   const bool bullCross = (fast[1] <= slow[1] && fast[0] > slow[0]);
   const bool bearCross = (fast[1] >= slow[1] && fast[0] < slow[0]);

   if(bullCross && rsi[0] < InpRSIBuyMax)
      return 1;
   if(bearCross && rsi[0] > InpRSISellMin)
      return -1;

   return 0;
}

//+------------------------------------------------------------------+
bool IsNewBar()
{
   const datetime barTime = iTime(_Symbol, InpTF, 0);
   if(barTime == 0)
      return false;
   if(barTime == g_lastBarTime)
      return false;
   g_lastBarTime = barTime;
   return true;
}
//+------------------------------------------------------------------+
