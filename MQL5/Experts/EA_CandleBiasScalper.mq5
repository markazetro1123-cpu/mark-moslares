//+------------------------------------------------------------------+
//| EA_CandleBiasScalper.mq5                                         |
//| Candle-Bias One-Way Trailing Pending Scalper                     |
//| XAUUSD / US30 | Any timeframe | Deriv / Tickmill compatible      |
//+------------------------------------------------------------------+
#property copyright "Mark Moslares"
#property link      "https://github.com/markazetro1123-cpu/mark-moslares"
#property version   "2.11"
#property description "Two toggleable strategies — fixed price distances (no ATR)"

#include <Trade/Trade.mqh>

//======================================================================
// Inputs
//======================================================================
input group "=== Strategies (true/false) ==="
input bool   InpStratCandleColor    = true;    // [1] Candle Color: GREEN=BUY only / RED=SELL only
input bool   InpStratOpposite       = false;   // [2] Opposite: DOWN move=BUY pending / UP move=SELL pending

input group "=== Entry ==="
input double InpBufferDistance      = 1.0;     // Buffer from candle open (price)
input double InpPendingOffset       = 0.2;     // Pending offset from price
input bool   InpAllowFlip           = false;   // Flip if both sides fill
input long   InpMagic               = 260715;  // Magic number

input group "=== Profit ==="
input double InpSecureProfit        = 0.2;     // Secure floor (price)
input double InpTrailDistance       = 0.1;     // Trail distance from current price

input group "=== Filters ==="
input double InpMaxSpreadPoints     = 0;       // Max spread in points (0 = off)
input int    InpCooldownSeconds     = 0;       // Wait after close (0 = off)

input group "=== Risk ==="
input bool   InpUseSmartRisk        = true;    // Smart risk manager
input double InpBaseRiskPercent     = 2.0;     // Risk % of equity per trade
input double InpRiskStepPerTier     = 0.25;    // Reduce risk % per equity tier
input double InpMinRiskPercent      = 1.0;     // Floor risk %
input double InpFixedLot            = 0.0;     // Fixed lot (0 = smart/min)
input double InpEmergencyStopDist   = 5.0;     // Emergency SL distance (price)
input double InpMaxDailyLossPct     = 10.0;    // Max daily loss % then pause

input group "=== Runtime ==="
input int    InpSlippagePoints      = 30;      // Max slippage (points)
input bool   InpAllowBuy            = true;    // Allow BUY side
input bool   InpAllowSell           = true;    // Allow SELL side

//======================================================================
// Helpers
//======================================================================
double CBR_Point(const string symbol)
{
   double p = SymbolInfoDouble(symbol, SYMBOL_POINT);
   return (p > 0.0 ? p : _Point);
}

int CBR_Digits(const string symbol)
{
   return (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
}

double CBR_NormalizePrice(const string symbol, double price)
{
   return NormalizeDouble(price, CBR_Digits(symbol));
}

double CBR_NormalizeVolume(const string symbol, double volume)
{
   const double vmin  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   const double vmax  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   const double vstep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(vstep <= 0.0)
      return vmin;
   volume = MathFloor(volume / vstep + 1e-12) * vstep;
   volume = MathMax(vmin, MathMin(vmax, volume));
   int volDigits = 2;
   if(vstep < 0.1)  volDigits = 2;
   if(vstep < 0.01) volDigits = 3;
   if(vstep >= 1.0) volDigits = 0;
   return NormalizeDouble(volume, volDigits);
}

bool CBR_SelectFilling(const string symbol, ENUM_ORDER_TYPE_FILLING &filling)
{
   const int modes = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
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

double CBR_StopsLevelDistance(const string symbol)
{
   const int stops  = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const int freeze = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return MathMax(stops, freeze) * CBR_Point(symbol);
}

double CBR_SpreadPrice(const string symbol)
{
   const double ask = SymbolInfoDouble(symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(symbol, SYMBOL_BID);
   return MathMax(0.0, ask - bid);
}

bool CBR_IsTradeAllowed(const string symbol)
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;
   const long mode = SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED)
      return false;
   return true;
}

bool CBR_SpreadOk(const string symbol, const double maxSpreadPoints)
{
   if(maxSpreadPoints <= 0.0)
      return true;
   const double spreadPts = CBR_SpreadPrice(symbol) / CBR_Point(symbol);
   return (spreadPts <= maxSpreadPoints);
}

bool CBR_GetOurPosition(const string symbol, const long magic, ulong &ticket, long &type)
{
   ticket = 0;
   type = -1;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic)
         continue;
      ticket = t;
      type = PositionGetInteger(POSITION_TYPE);
      return true;
   }
   return false;
}

bool CBR_FindPending(const string symbol, const long magic, const long orderType, ulong &ticket, double &price)
{
   ticket = 0;
   price = 0.0;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      const ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol)
         continue;
      if(OrderGetInteger(ORDER_MAGIC) != magic)
         continue;
      if(OrderGetInteger(ORDER_TYPE) != orderType)
         continue;
      ticket = t;
      price = OrderGetDouble(ORDER_PRICE_OPEN);
      return true;
   }
   return false;
}

bool CBR_CancelPendingByType(CTrade &trade, const string symbol, const long magic, const long orderType)
{
   bool ok = true;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      const ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol)
         continue;
      if(OrderGetInteger(ORDER_MAGIC) != magic)
         continue;
      if(OrderGetInteger(ORDER_TYPE) != orderType)
         continue;
      if(!trade.OrderDelete(t))
         ok = false;
   }
   return ok;
}

bool CBR_CancelAllPending(CTrade &trade, const string symbol, const long magic)
{
   bool ok = true;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      const ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol)
         continue;
      if(OrderGetInteger(ORDER_MAGIC) != magic)
         continue;
      const long typ = OrderGetInteger(ORDER_TYPE);
      if(typ == ORDER_TYPE_BUY || typ == ORDER_TYPE_SELL)
         continue;
      if(!trade.OrderDelete(t))
         ok = false;
   }
   return ok;
}

double CBR_LossPerLotForDistance(const string symbol, const double priceDistance)
{
   if(priceDistance <= 0.0)
      return 0.0;
   const double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   const double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);
   if(tickSize <= 0.0 || tickValue <= 0.0)
      return 0.0;
   return (priceDistance / tickSize) * tickValue;
}

double CBR_LotForRiskMoney(const string symbol, const double riskMoney, const double stopDistance)
{
   const double lossPerLot = CBR_LossPerLotForDistance(symbol, stopDistance);
   if(lossPerLot <= 0.0 || riskMoney <= 0.0)
      return SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   return CBR_NormalizeVolume(symbol, riskMoney / lossPerLot);
}

double CBR_MaxLotByMargin(const string symbol, const double price, const ENUM_ORDER_TYPE type, const double maxMarginShare = 0.35)
{
   const double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   const double vmin = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   if(free <= 0.0)
      return vmin;

   double marginOne = 0.0;
   if(!OrderCalcMargin(type, symbol, 1.0, price, marginOne) || marginOne <= 0.0)
   {
      double marginMin = 0.0;
      if(!OrderCalcMargin(type, symbol, vmin, price, marginMin) || marginMin <= 0.0)
         return vmin;
      marginOne = marginMin / vmin;
   }

   return CBR_NormalizeVolume(symbol, (free * maxMarginShare) / marginOne);
}

struct CBRRiskPlan
{
   double riskPercent;
   double lot;
   int    tierIndex;
};

int CBR_TierIndex(const double equity)
{
   if(equity < 50.0)   return 0;
   if(equity < 100.0)  return 1;
   if(equity < 200.0)  return 2;
   if(equity < 350.0)  return 3;
   if(equity < 500.0)  return 4;
   if(equity < 750.0)  return 5;
   if(equity < 1000.0) return 6;
   return 7;
}

CBRRiskPlan CBR_BuildRiskPlan(const string symbol,
                              const double emergencyStopDistance,
                              const ENUM_ORDER_TYPE orderTypeForMargin,
                              const double refPrice)
{
   CBRRiskPlan plan;
   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   plan.tierIndex = CBR_TierIndex(equity);

   double risk = InpBaseRiskPercent - (plan.tierIndex * InpRiskStepPerTier);
   if(risk < InpMinRiskPercent)
      risk = InpMinRiskPercent;
   plan.riskPercent = risk;

   const double vmin = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   const double riskMoney = equity * (plan.riskPercent / 100.0);
   double lot = CBR_LotForRiskMoney(symbol, riskMoney, emergencyStopDistance);

   const double maxMarginLot = CBR_MaxLotByMargin(symbol, refPrice, orderTypeForMargin, 0.35);
   lot = MathMin(lot, maxMarginLot);
   plan.lot = CBR_NormalizeVolume(symbol, lot);
   if(plan.lot < vmin)
      plan.lot = vmin;
   return plan;
}

//======================================================================
// Globals
//======================================================================
CTrade          g_trade;
string          g_symbol;
ENUM_TIMEFRAMES g_tf;
datetime        g_candleOpenTime = 0;
double          g_candleOpen     = 0.0;
int             g_candleColor    = 0;  // +1 green, -1 red, 0 doji/flat
bool            g_dailyLocked    = false;
double          g_dayStartEquity = 0.0;
int             g_dayStamp       = -1;
datetime        g_cooldownUntil  = 0;
bool            g_hadPosition    = false;

//======================================================================
// Forward decls
//======================================================================
void RefreshCandleContext(const bool force);
void UpdateDailyLock();
void EnforceSinglePosition();
void EnforceSinglePositionNoFlip();
void ManageEntryPendings();
void ManageCounterPendingWhileInPosition(const long posType);
void EnsureBuyStop_OneWayDown();
void EnsureSellStop_OneWayUp();
void ManageOpenPosition(const ulong ticket, const long posType);
double ComputeLot(const ENUM_ORDER_TYPE marginType, const double refPrice);
bool BufferPassedSell();
bool BufferPassedBuy();
bool InCooldown();
void ResolveWantedSides(bool &wantBuy, bool &wantSell);

//======================================================================
int OnInit()
{
   g_symbol = _Symbol;
   g_tf     = (ENUM_TIMEFRAMES)_Period;

   if(!SymbolSelect(g_symbol, true))
   {
      Print("ERROR: SymbolSelect failed for ", g_symbol);
      return INIT_FAILED;
   }
   if(!InpStratCandleColor && !InpStratOpposite)
   {
      Print("ERROR: enable at least one strategy (InpStratCandleColor and/or InpStratOpposite)");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpBufferDistance < 0.0 || InpPendingOffset < 0.0 ||
      InpSecureProfit < 0.0 || InpTrailDistance < 0.0 || InpEmergencyStopDist < 0.0)
   {
      Print("ERROR: distances must be >= 0");
      return INIT_PARAMETERS_INCORRECT;
   }

   ENUM_ORDER_TYPE_FILLING filling;
   CBR_SelectFilling(g_symbol, filling);
   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetDeviationInPoints(InpSlippagePoints);
   g_trade.SetTypeFilling(filling);
   g_trade.SetAsyncMode(false);

   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   g_dayStamp = dt.day_of_year;

   RefreshCandleContext(true);

   PrintFormat("CandleBiasScalper v2.11 ready | %s | %s | Strat1_CandleColor=%s Strat2_Opposite=%s | buffer=%.5f offset=%.5f",
               g_symbol, EnumToString(g_tf),
               (InpStratCandleColor ? "ON" : "OFF"),
               (InpStratOpposite ? "ON" : "OFF"),
               InpBufferDistance, InpPendingOffset);
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
}

void OnTick()
{
   if(!CBR_IsTradeAllowed(g_symbol))
      return;

   UpdateDailyLock();
   if(g_dailyLocked)
      return;

   RefreshCandleContext(false);

   ulong posTicket = 0;
   long  posType   = -1;
   const bool hasPos = CBR_GetOurPosition(g_symbol, InpMagic, posTicket, posType);

   if(g_hadPosition && !hasPos)
   {
      if(InpCooldownSeconds > 0)
         g_cooldownUntil = TimeCurrent() + InpCooldownSeconds;
      CBR_CancelAllPending(g_trade, g_symbol, InpMagic);
   }
   g_hadPosition = hasPos;

   if(InpAllowFlip)
      EnforceSinglePosition();
   else
      EnforceSinglePositionNoFlip();

   if(hasPos)
   {
      ManageOpenPosition(posTicket, posType);
      if(InpAllowFlip)
         ManageCounterPendingWhileInPosition(posType);
      else
         CBR_CancelAllPending(g_trade, g_symbol, InpMagic);
      return;
   }

   if(InCooldown())
      return;

   if(!CBR_SpreadOk(g_symbol, InpMaxSpreadPoints))
      return;

   ManageEntryPendings();
}

void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(InpAllowFlip)
      EnforceSinglePosition();
   else
      EnforceSinglePositionNoFlip();
}

//======================================================================
bool InCooldown()
{
   return (g_cooldownUntil > 0 && TimeCurrent() < g_cooldownUntil);
}

void EnforceSinglePosition()
{
   ulong buyTicket = 0, sellTicket = 0;
   datetime buyTime = 0, sellTime = 0;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      const long typ = PositionGetInteger(POSITION_TYPE);
      const datetime tm = (datetime)PositionGetInteger(POSITION_TIME);
      if(typ == POSITION_TYPE_BUY)
      {
         if(buyTicket == 0 || tm >= buyTime)
         {
            buyTicket = t;
            buyTime = tm;
         }
      }
      else if(typ == POSITION_TYPE_SELL)
      {
         if(sellTicket == 0 || tm >= sellTime)
         {
            sellTicket = t;
            sellTime = tm;
         }
      }
   }

   if(buyTicket > 0 && sellTicket > 0)
   {
      if(buyTime >= sellTime)
      {
         g_trade.PositionClose(sellTicket);
         CBR_CancelPendingByType(g_trade, g_symbol, InpMagic, ORDER_TYPE_BUY_STOP);
         Print("FLIP: SELL closed, BUY kept");
      }
      else
      {
         g_trade.PositionClose(buyTicket);
         CBR_CancelPendingByType(g_trade, g_symbol, InpMagic, ORDER_TYPE_SELL_STOP);
         Print("FLIP: BUY closed, SELL kept");
      }
   }
}

void EnforceSinglePositionNoFlip()
{
   ulong buyTicket = 0, sellTicket = 0;
   datetime buyTime = 0, sellTime = 0;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagic)
         continue;

      const long typ = PositionGetInteger(POSITION_TYPE);
      const datetime tm = (datetime)PositionGetInteger(POSITION_TIME);
      if(typ == POSITION_TYPE_BUY)
      {
         if(buyTicket == 0 || tm >= buyTime)
         {
            buyTicket = t;
            buyTime = tm;
         }
      }
      else if(typ == POSITION_TYPE_SELL)
      {
         if(sellTicket == 0 || tm >= sellTime)
         {
            sellTicket = t;
            sellTime = tm;
         }
      }
   }

   if(buyTicket > 0 && sellTicket > 0)
   {
      if(buyTime <= sellTime)
      {
         g_trade.PositionClose(sellTicket);
         Print("NO-FLIP: closed newer SELL");
      }
      else
      {
         g_trade.PositionClose(buyTicket);
         Print("NO-FLIP: closed newer BUY");
      }
   }
}

void UpdateDailyLock()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != g_dayStamp)
   {
      g_dayStamp = dt.day_of_year;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_dailyLocked = false;
   }
   if(InpMaxDailyLossPct <= 0.0 || g_dayStartEquity <= 0.0)
      return;

   const double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   const double ddPct = ((g_dayStartEquity - eq) / g_dayStartEquity) * 100.0;
   if(ddPct >= InpMaxDailyLossPct)
   {
      if(!g_dailyLocked)
      {
         PrintFormat("Daily loss lock: %.2f%%", ddPct);
         CBR_CancelAllPending(g_trade, g_symbol, InpMagic);
      }
      g_dailyLocked = true;
   }
}

void RefreshCandleContext(const bool force)
{
   const datetime t = iTime(g_symbol, g_tf, 0);
   const double   o = iOpen(g_symbol, g_tf, 0);
   if(t == 0 || o <= 0.0)
      return;

   if(force || t != g_candleOpenTime)
   {
      if(!force && g_candleOpenTime != 0)
      {
         CBR_CancelAllPending(g_trade, g_symbol, InpMagic);
         PrintFormat("New candle %s open=%.5f — pending reset",
                     TimeToString(t, TIME_DATE|TIME_MINUTES), o);
      }
      g_candleOpenTime = t;
      g_candleOpen = o;
   }
   else
      g_candleOpen = o;

   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double mid = (bid + ask) * 0.5;

   if(mid > g_candleOpen + CBR_Point(g_symbol) * 0.5)      g_candleColor = +1; // green
   else if(mid < g_candleOpen - CBR_Point(g_symbol) * 0.5) g_candleColor = -1; // red
   else                                                     g_candleColor = 0;
}

bool BufferPassedSell()
{
   return ((g_candleOpen - SymbolInfoDouble(g_symbol, SYMBOL_BID)) >= InpBufferDistance);
}

bool BufferPassedBuy()
{
   return ((SymbolInfoDouble(g_symbol, SYMBOL_ASK) - g_candleOpen) >= InpBufferDistance);
}

double ComputeLot(const ENUM_ORDER_TYPE marginType, const double refPrice)
{
   if(InpFixedLot > 0.0)
      return CBR_NormalizeVolume(g_symbol, InpFixedLot);
   if(!InpUseSmartRisk)
      return SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);

   CBRRiskPlan plan = CBR_BuildRiskPlan(g_symbol, InpEmergencyStopDist, marginType, refPrice);
   return plan.lot;
}

void ResolveWantedSides(bool &wantBuy, bool &wantSell)
{
   wantBuy  = false;
   wantSell = false;

   // Strategy [1] Candle Color: GREEN=BUY / RED=SELL
   if(InpStratCandleColor)
   {
      if(g_candleColor > 0 && InpAllowBuy && BufferPassedBuy())
         wantBuy = true;
      if(g_candleColor < 0 && InpAllowSell && BufferPassedSell())
         wantSell = true;
   }

   // Strategy [2] Opposite: DOWN=BUY pending / UP=SELL pending
   if(InpStratOpposite)
   {
      if(BufferPassedSell() && InpAllowBuy)
         wantBuy = true;
      if(BufferPassedBuy() && InpAllowSell)
         wantSell = true;
   }
}

void ManageEntryPendings()
{
   bool wantBuy  = false;
   bool wantSell = false;
   ResolveWantedSides(wantBuy, wantSell);

   if(wantBuy)
      EnsureBuyStop_OneWayDown();
   else
      CBR_CancelPendingByType(g_trade, g_symbol, InpMagic, ORDER_TYPE_BUY_STOP);

   if(wantSell)
      EnsureSellStop_OneWayUp();
   else
      CBR_CancelPendingByType(g_trade, g_symbol, InpMagic, ORDER_TYPE_SELL_STOP);
}

void ManageCounterPendingWhileInPosition(const long posType)
{
   if(posType == POSITION_TYPE_SELL)
   {
      CBR_CancelPendingByType(g_trade, g_symbol, InpMagic, ORDER_TYPE_SELL_STOP);
      if(InpAllowBuy)
         EnsureBuyStop_OneWayDown();
   }
   else if(posType == POSITION_TYPE_BUY)
   {
      CBR_CancelPendingByType(g_trade, g_symbol, InpMagic, ORDER_TYPE_BUY_STOP);
      if(InpAllowSell)
         EnsureSellStop_OneWayUp();
   }
}

void EnsureBuyStop_OneWayDown()
{
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double minDist = MathMax(InpPendingOffset, CBR_StopsLevelDistance(g_symbol));
   const double desired = CBR_NormalizePrice(g_symbol, ask + minDist);

   ulong ticket = 0;
   double cur = 0.0;
   if(CBR_FindPending(g_symbol, InpMagic, ORDER_TYPE_BUY_STOP, ticket, cur))
   {
      if(cur <= ask)
      {
         g_trade.OrderDelete(ticket);
      }
      else
      {
         if(desired < cur - CBR_Point(g_symbol) * 0.5)
         {
            if(!g_trade.OrderModify(ticket, desired, 0.0, 0.0, ORDER_TIME_GTC, 0))
               Print("BUY_STOP modify fail: ", g_trade.ResultRetcodeDescription());
         }
         return;
      }
   }

   if(!CBR_FindPending(g_symbol, InpMagic, ORDER_TYPE_BUY_STOP, ticket, cur))
   {
      const double lot = ComputeLot(ORDER_TYPE_BUY_STOP, desired);
      if(!g_trade.BuyStop(lot, desired, g_symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "CBR BUY_STOP"))
         Print("BUY_STOP place fail: ", g_trade.ResultRetcodeDescription());
   }
}

void EnsureSellStop_OneWayUp()
{
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double minDist = MathMax(InpPendingOffset, CBR_StopsLevelDistance(g_symbol));
   const double desired = CBR_NormalizePrice(g_symbol, bid - minDist);

   ulong ticket = 0;
   double cur = 0.0;
   if(CBR_FindPending(g_symbol, InpMagic, ORDER_TYPE_SELL_STOP, ticket, cur))
   {
      if(cur >= bid)
      {
         g_trade.OrderDelete(ticket);
      }
      else
      {
         if(desired > cur + CBR_Point(g_symbol) * 0.5)
         {
            if(!g_trade.OrderModify(ticket, desired, 0.0, 0.0, ORDER_TIME_GTC, 0))
               Print("SELL_STOP modify fail: ", g_trade.ResultRetcodeDescription());
         }
         return;
      }
   }

   if(!CBR_FindPending(g_symbol, InpMagic, ORDER_TYPE_SELL_STOP, ticket, cur))
   {
      const double lot = ComputeLot(ORDER_TYPE_SELL_STOP, desired);
      if(!g_trade.SellStop(lot, desired, g_symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "CBR SELL_STOP"))
         Print("SELL_STOP place fail: ", g_trade.ResultRetcodeDescription());
   }
}

void ManageOpenPosition(const ulong ticket, const long posType)
{
   if(!PositionSelectByTicket(ticket))
      return;

   const double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
   const double sl        = PositionGetDouble(POSITION_SL);
   const double tp        = PositionGetDouble(POSITION_TP);
   const double bid       = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask       = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double stopsDist = CBR_StopsLevelDistance(g_symbol);

   if(sl <= 0.0 && InpEmergencyStopDist > 0.0)
   {
      double emSL = (posType == POSITION_TYPE_BUY)
                    ? CBR_NormalizePrice(g_symbol, openPrice - InpEmergencyStopDist)
                    : CBR_NormalizePrice(g_symbol, openPrice + InpEmergencyStopDist);
      g_trade.PositionModify(ticket, emSL, tp);
      return;
   }

   if(posType == POSITION_TYPE_BUY)
   {
      if(bid - openPrice < InpSecureProfit)
         return;

      double newSL = CBR_NormalizePrice(g_symbol, bid - InpTrailDistance);
      const double floorSL = CBR_NormalizePrice(g_symbol, openPrice + (InpSecureProfit - InpTrailDistance));
      if(newSL < floorSL)
         newSL = floorSL;

      if(newSL > openPrice && (sl <= 0.0 || newSL > sl + CBR_Point(g_symbol) * 0.5))
      {
         if(bid - newSL >= stopsDist)
            g_trade.PositionModify(ticket, newSL, tp);
      }
   }
   else if(posType == POSITION_TYPE_SELL)
   {
      if(openPrice - ask < InpSecureProfit)
         return;

      double newSL = CBR_NormalizePrice(g_symbol, ask + InpTrailDistance);
      const double floorSL = CBR_NormalizePrice(g_symbol, openPrice - (InpSecureProfit - InpTrailDistance));
      if(newSL > floorSL)
         newSL = floorSL;

      if(newSL < openPrice && (sl <= 0.0 || newSL < sl - CBR_Point(g_symbol) * 0.5))
      {
         if(newSL - ask >= stopsDist)
            g_trade.PositionModify(ticket, newSL, tp);
      }
   }
}

//+------------------------------------------------------------------+
