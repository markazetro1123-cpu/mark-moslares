//+------------------------------------------------------------------+
//|                                       PovertyScalperClone.mq4     |
//|                                                                  |
//|  MetaTrader 4 (MQL4) port of the M1 momentum scalper that        |
//|  replicates the publicly described "Poverty Scalper Robot" style.|
//|    - M1 scalping (majors / XAUUSD)                               |
//|    - EMA cross + RSI + candle-body momentum entries              |
//|    - Fixed TP/SL, spread filter, session filter, trailing        |
//|    - Max equity drawdown guard, on-chart stats panel             |
//|                                                                  |
//|  Transparent re-implementation for study/backtesting. NO hidden  |
//|  martingale/grid. Test on DEMO first.                            |
//+------------------------------------------------------------------+
#property copyright "Educational clone - for study & backtesting only"
#property link      "https://github.com/markazetro1123-cpu/mark-moslares"
#property version   "1.00"
#property strict

//====================================================================
//  INPUTS
//====================================================================
extern string  H1                 = "=== General ===";
extern int     InpMagic           = 20260726;   // Magic number (unique per chart)
extern double  InpLots            = 0.01;       // Fixed lot size
extern int     InpMaxPositions    = 1;          // Max simultaneous positions (this symbol)
extern int     InpMaxSpreadPoints = 20;         // Max allowed spread in points (0 = ignore)
extern int     InpSlippagePoints  = 10;         // Max slippage (points)

extern string  H2                 = "=== Targets (points) — tight scalper ===";
extern int     InpTakeProfitPts   = 30;         // Take Profit (points)
extern int     InpStopLossPts     = 30;         // Stop Loss (points)
extern bool    InpUseTrailing     = true;       // Enable trailing stop
extern int     InpTrailStartPts   = 15;         // Trailing: profit to arm (points)
extern int     InpTrailStepPts    = 10;         // Trailing: trail distance (points)

extern string  H3                 = "=== Entry (momentum + trend) ===";
extern int     InpEmaFast         = 8;          // Fast EMA period
extern int     InpEmaSlow         = 21;         // Slow EMA period
extern int     InpRsiPeriod       = 14;         // RSI period
extern double  InpRsiBuyLevel     = 55.0;       // RSI must be >= this for BUY
extern double  InpRsiSellLevel    = 45.0;       // RSI must be <= this for SELL
extern int     InpMomentumBodyPts = 30;         // Min body of last candle (points)

extern string  H4                 = "=== Session filter (server time) ===";
extern bool    InpUseSession      = true;       // Restrict to a session window
extern int     InpSessionStartHour= 13;         // Start hour (server) ~ London/NY overlap
extern int     InpSessionEndHour  = 17;         // End hour (server)
extern bool    InpTradeFriday     = true;       // Allow Friday trading
extern int     InpFridayStopHour  = 20;         // Stop new trades Friday after this hour

extern string  H5                 = "=== Risk guard ===";
extern double  InpMaxDrawdownPct  = 20.0;       // Max equity drawdown % (0 = off)
extern bool    InpCloseAllOnHalt  = false;      // Close trades when guard trips

extern string  H6                 = "=== Display ===";
extern bool    InpShowPanel       = true;       // Show on-chart stats panel

//====================================================================
//  GLOBALS
//====================================================================
double   g_equityPeak = 0.0;
bool     g_halted     = false;
datetime g_lastBarTime = 0;

//====================================================================
//  INIT / DEINIT
//====================================================================
int OnInit()
{
   g_equityPeak = AccountEquity();
   g_halted     = false;
   Print("PovertyScalperClone (MT4) init on ", Symbol(),
         " point=", DoubleToString(Point, Digits), " digits=", Digits);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   Comment("");
}

//====================================================================
//  MAIN TICK
//====================================================================
void OnTick()
{
   if(InpUseTrailing)
      ManageTrailing();

   UpdateRiskGuard();

   if(InpShowPanel)
      DrawPanel();

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
      OpenTrade(OP_BUY);
   else if(signal < 0)
      OpenTrade(OP_SELL);
}

//====================================================================
//  SIGNAL (last closed M1 bar, shift 1)
//====================================================================
int GetSignal()
{
   double emaFast = iMA(NULL, PERIOD_M1, InpEmaFast, 0, MODE_EMA, PRICE_CLOSE, 1);
   double emaSlow = iMA(NULL, PERIOD_M1, InpEmaSlow, 0, MODE_EMA, PRICE_CLOSE, 1);
   double rsi     = iRSI(NULL, PERIOD_M1, InpRsiPeriod, PRICE_CLOSE, 1);

   double openPrev  = iOpen(NULL,  PERIOD_M1, 1);
   double closePrev = iClose(NULL, PERIOD_M1, 1);
   if(openPrev == 0.0 || closePrev == 0.0) return 0;

   double bodyPts = MathAbs(closePrev - openPrev) / Point;
   if(bodyPts < InpMomentumBodyPts) return 0;

   bool bullTrend  = emaFast > emaSlow;
   bool bearTrend  = emaFast < emaSlow;
   bool bullCandle = closePrev > openPrev;
   bool bearCandle = closePrev < openPrev;

   if(bullTrend && bullCandle && rsi >= InpRsiBuyLevel)
      return 1;
   if(bearTrend && bearCandle && rsi <= InpRsiSellLevel)
      return -1;
   return 0;
}

//====================================================================
//  ORDER EXECUTION
//====================================================================
void OpenTrade(const int cmd)
{
   RefreshRates();
   double price = (cmd == OP_BUY) ? Ask : Bid;
   price = NormalizeDouble(price, Digits);

   // Respect broker minimum stop distance.
   int stopsLevel = (int)MarketInfo(Symbol(), MODE_STOPLEVEL);
   int slPts = InpStopLossPts;
   int tpPts = InpTakeProfitPts;
   if(slPts > 0 && slPts < stopsLevel + 1) slPts = stopsLevel + 1;
   if(tpPts > 0 && tpPts < stopsLevel + 1) tpPts = stopsLevel + 1;

   double sl = 0.0, tp = 0.0;
   if(cmd == OP_BUY)
   {
      if(slPts > 0) sl = price - slPts * Point;
      if(tpPts > 0) tp = price + tpPts * Point;
   }
   else
   {
      if(slPts > 0) sl = price + slPts * Point;
      if(tpPts > 0) tp = price - tpPts * Point;
   }
   if(sl > 0) sl = NormalizeDouble(sl, Digits);
   if(tp > 0) tp = NormalizeDouble(tp, Digits);

   double lots = NormalizeLots(InpLots);

   int ticket = OrderSend(Symbol(), cmd, lots, price, InpSlippagePoints,
                          sl, tp, "PovertyScalperClone", InpMagic, 0, clrNONE);
   if(ticket < 0)
      Print("OrderSend failed, err=", GetLastError());
}

//====================================================================
//  TRAILING STOP
//====================================================================
void ManageTrailing()
{
   int stopsLevel = (int)MarketInfo(Symbol(), MODE_STOPLEVEL);
   int trailStep  = InpTrailStepPts;
   if(trailStep < stopsLevel + 1) trailStep = stopsLevel + 1;

   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol())      continue;
      if(OrderMagicNumber() != InpMagic) continue;

      double openPrice = OrderOpenPrice();
      double curSL     = OrderStopLoss();
      double tp        = OrderTakeProfit();

      if(OrderType() == OP_BUY)
      {
         double profitPts = (Bid - openPrice) / Point;
         if(profitPts >= InpTrailStartPts)
         {
            double newSL = NormalizeDouble(Bid - trailStep * Point, Digits);
            if(newSL > openPrice && (curSL == 0.0 || newSL > curSL))
               if(!OrderModify(OrderTicket(), openPrice, newSL, tp, 0, clrNONE))
                  Print("OrderModify(buy) err=", GetLastError());
         }
      }
      else if(OrderType() == OP_SELL)
      {
         double profitPts = (openPrice - Ask) / Point;
         if(profitPts >= InpTrailStartPts)
         {
            double newSL = NormalizeDouble(Ask + trailStep * Point, Digits);
            if(newSL < openPrice && (curSL == 0.0 || newSL < curSL))
               if(!OrderModify(OrderTicket(), openPrice, newSL, tp, 0, clrNONE))
                  Print("OrderModify(sell) err=", GetLastError());
         }
      }
   }
}

//====================================================================
//  RISK GUARD
//====================================================================
void UpdateRiskGuard()
{
   double equity = AccountEquity();
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
      Print("RISK GUARD tripped: drawdown ", DoubleToString(ddPct, 2),
            "% >= ", DoubleToString(InpMaxDrawdownPct, 2), "%. New trades halted.");
      if(InpCloseAllOnHalt)
         CloseAllOwn();
   }
}

//====================================================================
//  HELPERS
//====================================================================
bool IsNewBar()
{
   datetime t = iTime(NULL, PERIOD_M1, 0);
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
   int spread = (int)MarketInfo(Symbol(), MODE_SPREAD);
   return (spread <= InpMaxSpreadPoints);
}

bool SessionAllowsTrading()
{
   if(!InpUseSession)
      return true;

   int dow = DayOfWeek(); // 0=Sun .. 6=Sat
   if(dow == 0 || dow == 6)
      return false;
   if(dow == 5)
   {
      if(!InpTradeFriday) return false;
      if(Hour() >= InpFridayStopHour) return false;
   }

   int h = Hour();
   if(InpSessionStartHour <= InpSessionEndHour)
      return (h >= InpSessionStartHour && h < InpSessionEndHour);
   return (h >= InpSessionStartHour || h < InpSessionEndHour);
}

int CountPositions()
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() == Symbol() && OrderMagicNumber() == InpMagic &&
         (OrderType() == OP_BUY || OrderType() == OP_SELL))
         count++;
   }
   return count;
}

void CloseAllOwn()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES)) continue;
      if(OrderSymbol() != Symbol())      continue;
      if(OrderMagicNumber() != InpMagic) continue;

      RefreshRates();
      if(OrderType() == OP_BUY)
         OrderClose(OrderTicket(), OrderLots(), Bid, InpSlippagePoints, clrNONE);
      else if(OrderType() == OP_SELL)
         OrderClose(OrderTicket(), OrderLots(), Ask, InpSlippagePoints, clrNONE);
   }
}

double NormalizeLots(double lots)
{
   double minLot  = MarketInfo(Symbol(), MODE_MINLOT);
   double maxLot  = MarketInfo(Symbol(), MODE_MAXLOT);
   double lotStep = MarketInfo(Symbol(), MODE_LOTSTEP);

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
   double equity  = AccountEquity();
   double balance = AccountBalance();
   double ddPct   = (g_equityPeak > 0.0)
                    ? (g_equityPeak - equity) / g_equityPeak * 100.0
                    : 0.0;
   int    spread  = (int)MarketInfo(Symbol(), MODE_SPREAD);

   string txt = StringConcatenate(
      "==== Poverty Scalper Clone (MT4) ====\n",
      "Symbol   : ", Symbol(), "  (M1)\n",
      "Balance  : ", DoubleToString(balance, 2), "\n",
      "Equity   : ", DoubleToString(equity, 2), "\n",
      "Peak eq. : ", DoubleToString(g_equityPeak, 2), "\n",
      "Drawdown : ", DoubleToString(ddPct, 2), "% (max ",
                     DoubleToString(InpMaxDrawdownPct, 1), "%)\n",
      "Spread   : ", spread, " pts (max ", InpMaxSpreadPoints, ")\n",
      "Open pos : ", CountPositions(), " / ", InpMaxPositions, "\n",
      "Session  : ", (SessionAllowsTrading() ? "OPEN" : "CLOSED"), "\n",
      "Status   : ", (g_halted ? "HALTED (risk guard)" : "RUNNING"));

   Comment(txt);
}
//+------------------------------------------------------------------+
