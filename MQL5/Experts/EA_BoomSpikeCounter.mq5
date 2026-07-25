//+------------------------------------------------------------------+
//| EA_BoomSpikeCounter.mq5                                          |
//| Boom 1000 / Boom 100 Spike-Counter EA v1.3                       |
//| Single-file | Any attached timeframe | Deriv MT5                 |
//| Spec-frozen rules — no indicators / martingale / grid / cooldown |
//+------------------------------------------------------------------+
#property copyright "Mark Moslares"
#property link      "https://github.com/markazetro1123-cpu/mark-moslares"
#property version   "1.31"
#property description "Boom Spike-Counter v1.31: BuyStop fill fix + chart slippage realism"

#include <Trade/Trade.mqh>

//======================================================================
// INPUTS (spec §23)
//======================================================================
input group "=== Core ==="
input long              MagicNumber     = 1001001;
input ENUM_TIMEFRAMES   WorkTF          = PERIOD_CURRENT; // CURRENT = attached chart TF
input bool              AllowTrading    = true;

input group "=== Lot Engine ==="
input double            StartLot        = 1.00;
input double            LotStep         = 0.50;
input double            MinLot          = 1.00;
input double            MaxLot          = 20.00;

input group "=== SELL / Counter ==="
input int               BuyStopCount    = 3;
input double            SL_Buffer       = 0.20;

input group "=== Slippage / Tester realism ==="
input int               SlippagePoints  = 50;    // Max deviation (points) — match noisy live fills
input bool              InpUseChartSpread = true; // Log/use current chart spread
input int               InpSpreadFloorPts = 0;    // Extra spread floor in points (0=off)
input double            InpEntrySlipPrice = 0.0;  // Extra adverse price slip on market SELL (price units)

input group "=== Retry / Broker ==="
input int               MaxRetries      = 3;
input int               RetryDelayMs    = 300;

//======================================================================
// STATE MACHINE (spec §3)
//======================================================================
enum ENUM_BSC_STATE
{
   WAIT_SELL_SETUP = 0,
   SELL_ACTIVE     = 1,
   BUY_ACTIVE      = 2,
   RESETTING       = 3
};

//======================================================================
// GLOBALS / MEMORY ENGINE (spec §20)
//======================================================================
CTrade          g_trade;
string          g_symbol;
ENUM_TIMEFRAMES g_tf;
ENUM_BSC_STATE  g_state           = WAIT_SELL_SETUP;

double          g_currentLot      = 1.0;
ulong           g_cycleId         = 0;
datetime        g_cycleStartTime  = 0;
double          g_cycleStartBal   = 0.0;
double          g_cycleStartEq    = 0.0;
double          g_cycleClosedPnL  = 0.0;
bool            g_cycleResultDone = false;
bool            g_emergencyFlag   = false;

ulong           g_sellTicket      = 0;
double          g_sharedLevel     = 0.0;   // SELL SL + BuyStop price
ulong           g_buyStopTickets[];

datetime        g_lastSellSignalBar   = 0;
datetime        g_lastBuyExitBar      = 0;
datetime        g_lastEarlyExitBar    = 0;
datetime        g_lastCycleResultBar  = 0;
datetime        g_waitBuyFillSince    = 0;   // SELL closed, waiting BuyStop fills
bool            g_waitingBuyFill      = false;

//======================================================================
// FORWARD DECLS
//======================================================================
ENUM_TIMEFRAMES BSC_ResolveTF();
void            BSC_SetState(const ENUM_BSC_STATE s);
bool            BSC_IsGreen(const int shift);
bool            BSC_IsRed(const int shift);
datetime        BSC_BarTime(const int shift);
double          BSC_Open(const int shift);
double          BSC_Close(const int shift);
double          BSC_Point();
int             BSC_Digits();
double          BSC_NormPrice(double price);
double          BSC_NormVol(double vol);
double          BSC_StopsDist();
double          BSC_ValidSellSL(double desired);
double          BSC_ValidBuyStop(double desired);
double          BSC_ResolveExecutableLot(const ENUM_ORDER_TYPE type, const double price);
bool            BSC_RetrySleep();
int             BSC_CountPositions(const long posType);
int             BSC_CountPendings(const long orderType);
ulong           BSC_FindOurSell();
bool            BSC_CloseAllByType(const long posType);
bool            BSC_DeleteAllPendings();
bool            BSC_DeleteBuyStops();
void            BSC_SyncBuyStopTickets();
bool            BSC_PlaceBuyStops(const double level, const double lot);
bool            BSC_ModifySellSL(const ulong ticket, const double newSL);
bool            BSC_ModifyAllBuyStops(const double newLevel);
void            BSC_RecoverState();
void            BSC_OnWaitSellSetup();
void            BSC_OnSellActive();
void            BSC_OnBuyActive();
void            BSC_ResetEngine();
void            BSC_EvaluateCycleAndAdjustLot();
double          BSC_EmergencyLossPct(const double equity);
bool            BSC_CheckEmergency();
void            BSC_TrailSharedLevel();
bool            BSC_OpenSellWithSL(const double sl, const double lot, ulong &ticketOut);
void            BSC_ActivateBuyMode();
bool            BSC_TryActivateBuyFromPendings();
double          BSC_EffectiveSpreadPrice();
double          BSC_BuyStopTriggerPrice();

//======================================================================
// ONINIT / ONDEINIT / ONTICK
//======================================================================
int OnInit()
{
   g_symbol = _Symbol;
   g_tf     = BSC_ResolveTF();

   if(!SymbolSelect(g_symbol, true))
   {
      Print("BSC ERROR: SymbolSelect failed: ", g_symbol);
      return INIT_FAILED;
   }
   if(BuyStopCount < 1)
   {
      Print("BSC ERROR: BuyStopCount must be >= 1");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(StartLot <= 0.0 || LotStep <= 0.0 || MinLot <= 0.0 || MaxLot < MinLot)
   {
      Print("BSC ERROR: invalid lot inputs");
      return INIT_PARAMETERS_INCORRECT;
   }

   g_currentLot = StartLot;
   ArrayResize(g_buyStopTickets, 0);
   g_waitingBuyFill = false;
   g_waitBuyFillSince = 0;

   ENUM_ORDER_TYPE_FILLING fill = ORDER_FILLING_IOC;
   const int modes = (int)SymbolInfoInteger(g_symbol, SYMBOL_FILLING_MODE);
   if((modes & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC)      fill = ORDER_FILLING_IOC;
   else if((modes & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) fill = ORDER_FILLING_FOK;
   else                                                         fill = ORDER_FILLING_RETURN;

   g_trade.SetExpertMagicNumber(MagicNumber);
   // Slippage / deviation — higher = closer to messy live fills in tester
   g_trade.SetDeviationInPoints(SlippagePoints);
   g_trade.SetTypeFilling(fill);
   g_trade.SetAsyncMode(false);

   BSC_RecoverState();

   PrintFormat("BSC v1.31 ready | symbol=%s tf=%s magic=%s lot=%.2f slipPts=%d entrySlip=%.5f spread~%.5f",
               g_symbol, EnumToString(g_tf), IntegerToString(MagicNumber), g_currentLot,
               SlippagePoints, InpEntrySlipPrice, BSC_EffectiveSpreadPrice());
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Print("BSC deinit reason=", reason);
}

void OnTick()
{
   if(!AllowTrading)
      return;
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
      return;
   if(SymbolInfoInteger(g_symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
      return;

   // Keep TF synced if user uses PERIOD_CURRENT
   g_tf = BSC_ResolveTF();

   // Keep deviation synced (tester/live)
   g_trade.SetDeviationInPoints(SlippagePoints);

   if(BSC_CheckEmergency())
      return;

   // Global safety: if BUY positions exist, always prefer BUY mode
   if(g_state != BUY_ACTIVE && BSC_CountPositions(POSITION_TYPE_BUY) > 0)
      BSC_ActivateBuyMode();

   switch(g_state)
   {
      case WAIT_SELL_SETUP: BSC_OnWaitSellSetup(); break;
      case SELL_ACTIVE:     BSC_OnSellActive();    break;
      case BUY_ACTIVE:      BSC_OnBuyActive();     break;
      case RESETTING:       BSC_ResetEngine();     break;
   }
}

// Catch BuyStop fills instantly (tester + live)
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(trans.symbol != g_symbol)
      return;

   // Deal magic check via history
   if(!HistoryDealSelect(trans.deal))
      return;
   if((long)HistoryDealGetInteger(trans.deal, DEAL_MAGIC) != MagicNumber)
      return;

   const long dealType = HistoryDealGetInteger(trans.deal, DEAL_TYPE);
   if(dealType == DEAL_TYPE_BUY)
   {
      const long entry = HistoryDealGetInteger(trans.deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT)
      {
         Print("BSC OnTradeTransaction: BUY deal detected → activate BUY mode");
         BSC_ActivateBuyMode();
      }
   }
}

//======================================================================
// SMART CANDLE ENGINE (spec §4)
//======================================================================
ENUM_TIMEFRAMES BSC_ResolveTF()
{
   if(WorkTF == PERIOD_CURRENT)
      return (ENUM_TIMEFRAMES)_Period;
   return WorkTF;
}

bool BSC_IsGreen(const int shift)
{
   const double o = BSC_Open(shift);
   const double c = BSC_Close(shift);
   return (c > o);
}

bool BSC_IsRed(const int shift)
{
   const double o = BSC_Open(shift);
   const double c = BSC_Close(shift);
   return (c < o);
}

datetime BSC_BarTime(const int shift) { return iTime(g_symbol, g_tf, shift); }
double   BSC_Open(const int shift)    { return iOpen(g_symbol, g_tf, shift); }
double   BSC_Close(const int shift)   { return iClose(g_symbol, g_tf, shift); }

//======================================================================
// BROKER VALIDATION / SMART STOP DISTANCE (spec §15–16)
//======================================================================
double BSC_Point()
{
   const double p = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   return (p > 0.0 ? p : _Point);
}

double BSC_EffectiveSpreadPrice()
{
   double spread = SymbolInfoDouble(g_symbol, SYMBOL_ASK) - SymbolInfoDouble(g_symbol, SYMBOL_BID);
   if(!InpUseChartSpread)
      spread = 0.0;
   if(InpSpreadFloorPts > 0)
   {
      const double floorPx = InpSpreadFloorPts * BSC_Point();
      if(spread < floorPx)
         spread = floorPx;
   }
   return MathMax(0.0, spread);
}

double BSC_BuyStopTriggerPrice()
{
   // Lowest BuyStop price (all should be same level)
   double px = g_sharedLevel;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      const ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL) != g_symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      if(OrderGetInteger(ORDER_TYPE) != ORDER_TYPE_BUY_STOP) continue;
      const double op = OrderGetDouble(ORDER_PRICE_OPEN);
      if(px <= 0.0 || op < px)
         px = op;
   }
   return px;
}

void BSC_ActivateBuyMode()
{
   // Close remaining SELL, delete unfilled BuyStops, switch
   if(BSC_CountPositions(POSITION_TYPE_SELL) > 0)
   {
      BSC_CloseAllByType(POSITION_TYPE_SELL);
      for(int r = 0; r < MaxRetries && BSC_CountPositions(POSITION_TYPE_SELL) > 0; ++r)
      {
         BSC_CloseAllByType(POSITION_TYPE_SELL);
         BSC_RetrySleep();
      }
   }
   BSC_DeleteBuyStops();
   g_sellTicket = 0;
   g_waitingBuyFill = false;
   g_waitBuyFillSince = 0;
   if(BSC_CountPositions(POSITION_TYPE_BUY) > 0)
   {
      BSC_SetState(BUY_ACTIVE);
      Print("BSC switch → BUY_ACTIVE (buys=", BSC_CountPositions(POSITION_TYPE_BUY), ")");
   }
}

bool BSC_TryActivateBuyFromPendings()
{
   if(BSC_CountPositions(POSITION_TYPE_BUY) > 0)
   {
      BSC_ActivateBuyMode();
      return true;
   }
   return false;
}

int BSC_Digits()
{
   return (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
}

double BSC_NormPrice(double price)
{
   return NormalizeDouble(price, BSC_Digits());
}

double BSC_NormVol(double vol)
{
   const double vmin  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   const double vmax  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   const double vstep = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   if(vstep <= 0.0) return vmin;
   vol = MathFloor(vol / vstep + 1e-12) * vstep;
   vol = MathMax(vmin, MathMin(vmax, vol));
   int d = 2;
   if(vstep < 0.01) d = 3;
   if(vstep >= 1.0) d = 0;
   return NormalizeDouble(vol, d);
}

double BSC_StopsDist()
{
   const int stops  = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const int freeze = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return MathMax(stops, freeze) * BSC_Point();
}

// SELL SL must be above Ask by broker distance
double BSC_ValidSellSL(double desired)
{
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double minLevel = ask + BSC_StopsDist();
   if(desired < minLevel)
      desired = minLevel;
   return BSC_NormPrice(desired);
}

// BuyStop must be above Ask by broker distance
double BSC_ValidBuyStop(double desired)
{
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double minLevel = ask + BSC_StopsDist();
   if(desired < minLevel)
      desired = minLevel;
   return BSC_NormPrice(desired);
}

//======================================================================
// DYNAMIC LOT + MARGIN PROTECTION (spec §12, §17)
//======================================================================
double BSC_ResolveExecutableLot(const ENUM_ORDER_TYPE type, const double price)
{
   // Strategy lot clamped to inputs, then broker-normalized.
   // For Boom 100 / Boom 1000 volume differences, broker vmin/vmax always win.
   double lot = g_currentLot;
   if(lot < MinLot) lot = MinLot;
   if(lot > MaxLot) lot = MaxLot;

   const double vmin = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   const double vmax = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   if(lot < vmin) lot = vmin;
   if(lot > vmax) lot = vmax;

   for(int guard = 0; guard < 60; ++guard)
   {
      double tryLot = BSC_NormVol(lot);
      if(tryLot < vmin)
         break;
      if(tryLot > vmax)
      {
         lot = vmax;
         continue;
      }

      double margin = 0.0;
      if(!OrderCalcMargin(type, g_symbol, tryLot, price, margin) || margin <= 0.0)
         return tryLot; // calc unavailable — use normalized lot

      if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) >= margin)
         return tryLot;

      lot -= LotStep;
      if(lot < vmin)
         lot = vmin;
      if(tryLot <= vmin + 1e-12)
         break;
   }

   Print("BSC: no valid executable lot available");
   return 0.0;
}

bool BSC_RetrySleep()
{
   if(RetryDelayMs > 0)
      Sleep(RetryDelayMs);
   return true;
}

//======================================================================
// POSITION / ORDER HELPERS (magic + symbol isolation §22)
//======================================================================
int BSC_CountPositions(const long posType)
{
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(posType >= 0 && PositionGetInteger(POSITION_TYPE) != posType) continue;
      n++;
   }
   return n;
}

int BSC_CountPendings(const long orderType)
{
   int n = 0;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      const ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL) != g_symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      if(orderType >= 0 && OrderGetInteger(ORDER_TYPE) != orderType) continue;
      n++;
   }
   return n;
}

ulong BSC_FindOurSell()
{
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_SELL)
         return t;
   }
   return 0;
}

bool BSC_CloseAllByType(const long posType)
{
   bool allOk = true;
   for(int attempt = 0; attempt < MaxRetries; ++attempt)
   {
      allOk = true;
      for(int i = PositionsTotal() - 1; i >= 0; --i)
      {
         const ulong t = PositionGetTicket(i);
         if(t == 0 || !PositionSelectByTicket(t)) continue;
         if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
         if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
         if(posType >= 0 && PositionGetInteger(POSITION_TYPE) != posType) continue;
         if(!g_trade.PositionClose(t))
         {
            allOk = false;
            Print("BSC close fail ticket=", t, " : ", g_trade.ResultRetcodeDescription());
         }
      }
      if(posType >= 0 && BSC_CountPositions(posType) == 0) return true;
      if(posType < 0 && BSC_CountPositions(-1) == 0) return true;
      BSC_RetrySleep();
   }
   return (BSC_CountPositions(posType) == 0);
}

bool BSC_DeleteAllPendings()
{
   bool allOk = true;
   for(int attempt = 0; attempt < MaxRetries; ++attempt)
   {
      allOk = true;
      for(int i = OrdersTotal() - 1; i >= 0; --i)
      {
         const ulong t = OrderGetTicket(i);
         if(t == 0 || !OrderSelect(t)) continue;
         if(OrderGetString(ORDER_SYMBOL) != g_symbol) continue;
         if(OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
         const long typ = OrderGetInteger(ORDER_TYPE);
         if(typ == ORDER_TYPE_BUY || typ == ORDER_TYPE_SELL) continue;
         if(!g_trade.OrderDelete(t))
         {
            allOk = false;
            Print("BSC pending delete fail: ", g_trade.ResultRetcodeDescription());
         }
      }
      if(BSC_CountPendings(-1) == 0)
      {
         ArrayResize(g_buyStopTickets, 0);
         return true;
      }
      BSC_RetrySleep();
   }
   BSC_SyncBuyStopTickets();
   return (BSC_CountPendings(-1) == 0);
}

bool BSC_DeleteBuyStops()
{
   bool allOk = true;
   for(int attempt = 0; attempt < MaxRetries; ++attempt)
   {
      allOk = true;
      for(int i = OrdersTotal() - 1; i >= 0; --i)
      {
         const ulong t = OrderGetTicket(i);
         if(t == 0 || !OrderSelect(t)) continue;
         if(OrderGetString(ORDER_SYMBOL) != g_symbol) continue;
         if(OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
         if(OrderGetInteger(ORDER_TYPE) != ORDER_TYPE_BUY_STOP) continue;
         if(!g_trade.OrderDelete(t))
         {
            allOk = false;
            Print("BSC BuyStop delete fail: ", g_trade.ResultRetcodeDescription());
         }
      }
      if(BSC_CountPendings(ORDER_TYPE_BUY_STOP) == 0)
      {
         ArrayResize(g_buyStopTickets, 0);
         return true;
      }
      BSC_RetrySleep();
   }
   BSC_SyncBuyStopTickets();
   return (BSC_CountPendings(ORDER_TYPE_BUY_STOP) == 0);
}

void BSC_SyncBuyStopTickets()
{
   ArrayResize(g_buyStopTickets, 0);
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      const ulong t = OrderGetTicket(i);
      if(t == 0 || !OrderSelect(t)) continue;
      if(OrderGetString(ORDER_SYMBOL) != g_symbol) continue;
      if(OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;
      if(OrderGetInteger(ORDER_TYPE) != ORDER_TYPE_BUY_STOP) continue;
      const int n = ArraySize(g_buyStopTickets);
      ArrayResize(g_buyStopTickets, n + 1);
      g_buyStopTickets[n] = t;
   }
}

//======================================================================
// STATE HELPERS
//======================================================================
void BSC_SetState(const ENUM_BSC_STATE s)
{
   if(g_state == s) return;
   PrintFormat("BSC STATE %d -> %d", (int)g_state, (int)s);
   g_state = s;
}

void BSC_RecoverState()
{
   const int sells = BSC_CountPositions(POSITION_TYPE_SELL);
   const int buys  = BSC_CountPositions(POSITION_TYPE_BUY);
   BSC_SyncBuyStopTickets();

   if(buys > 0)
   {
      g_sellTicket = 0;
      BSC_SetState(BUY_ACTIVE);
      Print("BSC recover → BUY_ACTIVE buys=", buys);
      return;
   }
   if(sells > 0)
   {
      g_sellTicket = BSC_FindOurSell();
      if(g_sellTicket > 0 && PositionSelectByTicket(g_sellTicket))
         g_sharedLevel = PositionGetDouble(POSITION_SL);
      BSC_SetState(SELL_ACTIVE);
      Print("BSC recover → SELL_ACTIVE sells=", sells, " sharedLevel=", g_sharedLevel);
      return;
   }

   // Live BuyStops without position → wait for BUY fill (do NOT delete)
   if(BSC_CountPendings(ORDER_TYPE_BUY_STOP) > 0)
   {
      g_waitingBuyFill = true;
      g_waitBuyFillSince = TimeCurrent();
      g_sharedLevel = BSC_BuyStopTriggerPrice();
      BSC_SetState(SELL_ACTIVE);
      Print("BSC recover → SELL_ACTIVE (waiting BuyStop fills), level=", g_sharedLevel);
      return;
   }

   BSC_SetState(WAIT_SELL_SETUP);
   Print("BSC recover → WAIT_SELL_SETUP");
}

//======================================================================
// EMERGENCY BASKET LOSS (spec §14)
//======================================================================
double BSC_EmergencyLossPct(const double equity)
{
   if(equity < 100.0)     return 60.0;
   if(equity < 300.0)     return 50.0;
   if(equity < 1000.0)    return 40.0;
   if(equity < 3000.0)    return 35.0;
   if(equity < 5000.0)    return 30.0;
   if(equity < 10000.0)   return 25.0;
   if(equity < 50000.0)   return 20.0;
   if(equity < 100000.0)  return 15.0;
   return 10.0;
}

bool BSC_CheckEmergency()
{
   if(g_state != SELL_ACTIVE && g_state != BUY_ACTIVE)
      return false;
   if(g_cycleStartEq <= 0.0)
      return false;

   double basket = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      basket += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }

   const double pct = BSC_EmergencyLossPct(g_cycleStartEq);
   const double threshold = -(g_cycleStartEq * (pct / 100.0));
   if(basket > threshold)
      return false;

   PrintFormat("BSC EMERGENCY basket=%.2f threshold=%.2f (%.1f%% of eq %.2f)",
               basket, threshold, pct, g_cycleStartEq);
   g_emergencyFlag = true;
   BSC_CloseAllByType(-1);
   BSC_DeleteAllPendings();
   BSC_SetState(RESETTING);
   return true;
}

//======================================================================
// CYCLE RESULT + LOT STEP (spec §12–13)
//======================================================================
void BSC_EvaluateCycleAndAdjustLot()
{
   if(g_cycleResultDone)
      return;
   g_cycleResultDone = true;
   g_lastCycleResultBar = BSC_BarTime(0);

   // Approximate cycle result from equity change since cycle start
   // plus any remaining floating (should be ~0 after flat)
   double floating = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong t = PositionGetTicket(i);
      if(t == 0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL) != g_symbol) continue;
      if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      floating += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }

   const double eqNow = AccountInfoDouble(ACCOUNT_EQUITY);
   g_cycleClosedPnL = (eqNow - g_cycleStartEq) + floating;

   // Prefer deal history since cycle start for accuracy
   if(HistorySelect(g_cycleStartTime, TimeCurrent()))
   {
      double dealsNet = 0.0;
      const int total = HistoryDealsTotal();
      for(int i = 0; i < total; ++i)
      {
         const ulong d = HistoryDealGetTicket(i);
         if(d == 0) continue;
         if(HistoryDealGetString(d, DEAL_SYMBOL) != g_symbol) continue;
         if((long)HistoryDealGetInteger(d, DEAL_MAGIC) != MagicNumber) continue;
         const long entry = HistoryDealGetInteger(d, DEAL_ENTRY);
         if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT)
            continue;
         dealsNet += HistoryDealGetDouble(d, DEAL_PROFIT)
                   + HistoryDealGetDouble(d, DEAL_SWAP)
                   + HistoryDealGetDouble(d, DEAL_COMMISSION);
      }
      g_cycleClosedPnL = dealsNet;
   }

   PrintFormat("BSC CYCLE result pnl=%.2f emergency=%s",
               g_cycleClosedPnL, (g_emergencyFlag ? "Y" : "N"));

   if(g_cycleClosedPnL > 0.0)
   {
      g_currentLot += LotStep;
      if(g_currentLot > MaxLot) g_currentLot = MaxLot;
      PrintFormat("BSC LOT WIN → %.2f", g_currentLot);
   }
   else if(g_cycleClosedPnL < 0.0)
   {
      g_currentLot -= LotStep;
      if(g_currentLot < MinLot) g_currentLot = MinLot;
      PrintFormat("BSC LOT LOSS → %.2f", g_currentLot);
   }
   else
   {
      PrintFormat("BSC LOT BE → %.2f (unchanged)", g_currentLot);
   }
}

void BSC_ResetEngine()
{
   BSC_EvaluateCycleAndAdjustLot();
   BSC_DeleteAllPendings();
   g_sellTicket = 0;
   g_sharedLevel = 0.0;
   g_cycleId = 0;
   g_cycleStartTime = 0;
   g_cycleStartBal = 0.0;
   g_cycleStartEq = 0.0;
   g_emergencyFlag = false;
   g_waitingBuyFill = false;
   g_waitBuyFillSince = 0;
   // keep g_cycleResultDone true until new cycle starts
   BSC_SetState(WAIT_SELL_SETUP);
   Print("BSC RESET → WAIT_SELL_SETUP");
}

//======================================================================
// SELL ENTRY ENGINE (spec §5–7)
//======================================================================
bool BSC_OpenSellWithSL(const double sl, const double lot, ulong &ticketOut)
{
   ticketOut = 0;
   for(int attempt = 0; attempt < MaxRetries; ++attempt)
   {
      const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
      const double validSL = BSC_ValidSellSL(sl);
      if(validSL <= bid)
      {
         Print("BSC SELL aborted: invalid SL after broker adjust");
         return false;
      }

      // Adverse slippage for SELL = fill at lower price (worse). 0 = market.
      double entryPx = 0.0;
      if(InpEntrySlipPrice > 0.0)
         entryPx = BSC_NormPrice(bid - InpEntrySlipPrice);

      PrintFormat("BSC SELL send lot=%.2f bid=%.5f entryPx=%.5f slipPts=%d spread=%.5f SL=%.5f",
                  lot, bid, entryPx, SlippagePoints, BSC_EffectiveSpreadPrice(), validSL);

      if(!g_trade.Sell(lot, g_symbol, entryPx, validSL, 0.0, "BSC SELL"))
      {
         Print("BSC SELL open fail: ", g_trade.ResultRetcodeDescription());
         BSC_RetrySleep();
         continue;
      }

      ticketOut = g_trade.ResultOrder();
      // Prefer position ticket
      Sleep(50);
      ticketOut = BSC_FindOurSell();
      if(ticketOut == 0)
      {
         Print("BSC SELL opened but ticket not found yet");
         BSC_RetrySleep();
         ticketOut = BSC_FindOurSell();
      }
      if(ticketOut == 0)
         return false;

      if(!PositionSelectByTicket(ticketOut))
         return false;

      double curSL = PositionGetDouble(POSITION_SL);
      if(curSL <= 0.0)
      {
         if(!BSC_ModifySellSL(ticketOut, validSL))
         {
            Print("BSC SELL SL attach failed → close SELL immediately");
            g_trade.PositionClose(ticketOut);
            return false;
         }
      }
      g_sharedLevel = (PositionSelectByTicket(ticketOut) ? PositionGetDouble(POSITION_SL) : validSL);
      PrintFormat("BSC SELL open ok ticket=%s lot=%.2f SL=%.5f",
                  IntegerToString(ticketOut), lot, g_sharedLevel);
      return true;
   }
   return false;
}

bool BSC_ModifySellSL(const ulong ticket, const double newSL)
{
   for(int attempt = 0; attempt < MaxRetries; ++attempt)
   {
      if(!PositionSelectByTicket(ticket)) return false;
      const double tp = PositionGetDouble(POSITION_TP);
      const double valid = BSC_ValidSellSL(newSL);
      const double cur = PositionGetDouble(POSITION_SL);
      if(MathAbs(cur - valid) <= BSC_Point() * 0.5)
         return true;
      if(g_trade.PositionModify(ticket, valid, tp))
         return true;
      Print("BSC modify SELL SL fail: ", g_trade.ResultRetcodeDescription());
      BSC_RetrySleep();
   }
   return false;
}

bool BSC_PlaceBuyStops(const double level, const double lot)
{
   // Fresh set only — never exceed BuyStopCount
   BSC_DeleteBuyStops();

   const double price = BSC_ValidBuyStop(level);
   int placed = 0;
   ArrayResize(g_buyStopTickets, 0);

   for(int i = 0; i < BuyStopCount; ++i)
   {
      bool ok = false;
      for(int attempt = 0; attempt < MaxRetries; ++attempt)
      {
         // Guard against accidental 4th
         if(BSC_CountPendings(ORDER_TYPE_BUY_STOP) >= BuyStopCount)
         {
            ok = true;
            break;
         }
         const double px = BSC_ValidBuyStop(price);
         if(g_trade.BuyStop(lot, px, g_symbol, 0.0, 0.0, ORDER_TIME_GTC, 0, "BSC BUYSTOP"))
         {
            ok = true;
            placed++;
            break;
         }
         Print("BSC BuyStop place fail: ", g_trade.ResultRetcodeDescription());
         BSC_RetrySleep();
      }
      if(!ok)
         Print("BSC BuyStop #", i + 1, " failed permanently this cycle");
   }

   BSC_SyncBuyStopTickets();
   PrintFormat("BSC BuyStops placed=%d/%d level=%.5f lot=%.2f",
               BSC_CountPendings(ORDER_TYPE_BUY_STOP), BuyStopCount, price, lot);
   return (placed > 0 || BSC_CountPendings(ORDER_TYPE_BUY_STOP) > 0);
}

bool BSC_ModifyAllBuyStops(const double newLevel)
{
   const double level = BSC_ValidBuyStop(newLevel);
   BSC_SyncBuyStopTickets();
   bool ok = true;

   for(int i = 0; i < ArraySize(g_buyStopTickets); ++i)
   {
      const ulong t = g_buyStopTickets[i];
      if(t == 0 || !OrderSelect(t)) continue;
      const double cur = OrderGetDouble(ORDER_PRICE_OPEN);
      if(MathAbs(cur - level) <= BSC_Point() * 0.5)
         continue;
      // Only move downward for BuyStops (lower price)
      if(level >= cur - BSC_Point() * 0.5)
         continue;

      bool modOk = false;
      for(int attempt = 0; attempt < MaxRetries; ++attempt)
      {
         if(g_trade.OrderModify(t, level, 0.0, 0.0, ORDER_TIME_GTC, 0))
         {
            modOk = true;
            break;
         }
         Print("BSC BuyStop modify fail: ", g_trade.ResultRetcodeDescription());
         BSC_RetrySleep();
      }
      if(!modOk) ok = false;
   }
   return ok;
}

//======================================================================
// WAIT_SELL_SETUP
//======================================================================
void BSC_OnWaitSellSetup()
{
   if(BSC_CountPositions(POSITION_TYPE_BUY) > 0)
   {
      BSC_ActivateBuyMode();
      return;
   }
   if(BSC_CountPositions(POSITION_TYPE_SELL) > 0)
   {
      g_sellTicket = BSC_FindOurSell();
      BSC_SetState(SELL_ACTIVE);
      return;
   }
   // If BuyStops exist here, hand off to SELL_ACTIVE wait-fill logic (never wipe)
   if(BSC_CountPendings(ORDER_TYPE_BUY_STOP) > 0)
   {
      g_waitingBuyFill = true;
      g_waitBuyFillSince = TimeCurrent();
      g_sharedLevel = BSC_BuyStopTriggerPrice();
      BSC_SetState(SELL_ACTIVE);
      Print("BSC WAIT→SELL_ACTIVE handoff: protect live BuyStops");
      return;
   }

   // Closed candles: shift2 Green, shift1 Red
   if(!BSC_IsGreen(2) || !BSC_IsRed(1))
      return;

   const datetime signalBar = BSC_BarTime(1);
   if(signalBar == 0 || signalBar == g_lastSellSignalBar)
      return; // candle lock — one signal candle = one SELL

   // Desired SL = previous Green close + buffer
   const double greenClose = BSC_Close(2);
   double desiredSL = BSC_NormPrice(greenClose + SL_Buffer);
   desiredSL = BSC_ValidSellSL(desiredSL);

   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double lot = BSC_ResolveExecutableLot(ORDER_TYPE_SELL, bid);
   if(lot <= 0.0)
   {
      Print("BSC SELL signal skipped — no lot");
      return;
   }

   PrintFormat("BSC SELL SIGNAL bar=%s greenClose=%.5f desiredSL=%.5f lot=%.2f ask=%.5f bid=%.5f",
               TimeToString(signalBar, TIME_DATE|TIME_MINUTES), greenClose, desiredSL, lot, ask, bid);

   // Delete obsolete BuyStops before fresh SELL
   BSC_DeleteBuyStops();

   ulong ticket = 0;
   if(!BSC_OpenSellWithSL(desiredSL, lot, ticket))
   {
      Print("BSC SELL open failed — stay WAIT_SELL_SETUP");
      return;
   }

   g_lastSellSignalBar = signalBar;
   g_sellTicket = ticket;
   g_cycleId++;
   g_cycleStartTime = TimeCurrent();
   g_cycleStartBal  = AccountInfoDouble(ACCOUNT_BALANCE);
   g_cycleStartEq   = AccountInfoDouble(ACCOUNT_EQUITY);
   g_cycleClosedPnL = 0.0;
   g_cycleResultDone = false;
   g_emergencyFlag = false;

   // Place exactly 3 BuyStops at SELL SL
   if(g_sharedLevel <= 0.0)
      g_sharedLevel = desiredSL;
   BSC_PlaceBuyStops(g_sharedLevel, lot);

   BSC_SetState(SELL_ACTIVE);
}

//======================================================================
// ADAPTIVE TRAIL (spec §8)
//======================================================================
void BSC_TrailSharedLevel()
{
   if(g_sellTicket == 0 || !PositionSelectByTicket(g_sellTicket))
   {
      g_sellTicket = BSC_FindOurSell();
      if(g_sellTicket == 0) return;
   }

   // Desired shared level trails down with Ask + buffer (never up)
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double desired = BSC_ValidSellSL(ask + SL_Buffer);

   if(g_sharedLevel <= 0.0)
      g_sharedLevel = PositionGetDouble(POSITION_SL);

   // Only move downward
   if(g_sharedLevel > 0.0 && desired >= g_sharedLevel - BSC_Point() * 0.5)
      return;

   if(!BSC_ModifySellSL(g_sellTicket, desired))
      return;

   if(PositionSelectByTicket(g_sellTicket))
      g_sharedLevel = PositionGetDouble(POSITION_SL);
   else
      g_sharedLevel = desired;

   BSC_ModifyAllBuyStops(g_sharedLevel);
   PrintFormat("BSC TRAIL sharedLevel → %.5f", g_sharedLevel);
}

//======================================================================
// SELL_ACTIVE (spec §8–10)
//======================================================================
void BSC_OnSellActive()
{
   // Priority: BuyStop trigger → BUY positions
   if(BSC_TryActivateBuyFromPendings())
      return;

   const int sellCount = BSC_CountPositions(POSITION_TYPE_SELL);
   const int buyStops  = BSC_CountPendings(ORDER_TYPE_BUY_STOP);

   // FIX: SELL closed by SL at shared level — DO NOT delete BuyStops.
   // Wait for BuyStops to fill (this was why BUY never entered).
   if(sellCount == 0)
   {
      if(buyStops > 0)
      {
         if(!g_waitingBuyFill)
         {
            g_waitingBuyFill = true;
            g_waitBuyFillSince = TimeCurrent();
            PrintFormat("BSC SELL flat but %d BuyStop(s) live @ %.5f — WAITING for BUY fill (no delete)",
                        buyStops, BSC_BuyStopTriggerPrice());
         }

         // If Ask already through BuyStop level, keep waiting a bit for tester/broker fill
         const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
         const double trig = BSC_BuyStopTriggerPrice();
         if(trig > 0.0 && ask + BSC_Point() >= trig)
         {
            // Still no BUY position: some testers delay pending fill one tick
            if(BSC_TryActivateBuyFromPendings())
               return;
            // Soft timeout 15s while price is through level
            if(g_waitBuyFillSince > 0 && (TimeCurrent() - g_waitBuyFillSince) > 15)
            {
               Print("BSC WARN: Ask through BuyStop but no BUY fill after 15s — keep waiting one more cycle");
               g_waitBuyFillSince = TimeCurrent(); // extend once; don't delete yet
            }
            return;
         }

         // Price fell back far below trigger without filling → abandoned spike
         if(trig > 0.0 && ask < (trig - MathMax(SL_Buffer * 2.0, BSC_StopsDist() * 2.0)))
         {
            PrintFormat("BSC BuyStops abandoned (ask=%.5f << trig=%.5f) → reset", ask, trig);
            BSC_DeleteBuyStops();
            g_waitingBuyFill = false;
            BSC_SetState(RESETTING);
            return;
         }

         // Hard timeout 120s
         if(g_waitBuyFillSince > 0 && (TimeCurrent() - g_waitBuyFillSince) > 120)
         {
            Print("BSC BuyStop wait timeout 120s → reset");
            BSC_DeleteBuyStops();
            g_waitingBuyFill = false;
            BSC_SetState(RESETTING);
         }
         return;
      }

      // Truly flat — no SELL, no BUY, no BuyStops
      Print("BSC SELL flat with no BUY/BuyStops → reset");
      g_waitingBuyFill = false;
      BSC_SetState(RESETTING);
      return;
   }

   g_waitingBuyFill = false;

   // Early Green overlap exit (intrabar) — forming candle shift 0
   // Current forming Green AND Bid >= previous Red Open (shift 1)
   // Only if BuyStops have NOT been triggered (still SELL path, no spike fill)
   if(BSC_IsGreen(0))
   {
      const double prevRedOpen = BSC_Open(1);
      const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
      const datetime curBar = BSC_BarTime(0);
      if(bid >= prevRedOpen && curBar != g_lastEarlyExitBar)
      {
         // If price already reached shared BuyStop/SL level, treat as spike path — don't kill BuyStops
         const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
         if(g_sharedLevel > 0.0 && ask >= g_sharedLevel - BSC_Point())
         {
            Print("BSC overlap near sharedLevel — prefer BuyStop fill path, skip early-delete");
         }
         else
         {
            PrintFormat("BSC EARLY GREEN OVERLAP bid=%.5f redOpen=%.5f — close SELL",
                        bid, prevRedOpen);
            g_lastEarlyExitBar = curBar;
            BSC_CloseAllByType(POSITION_TYPE_SELL);
            for(int r = 0; r < MaxRetries && BSC_CountPositions(POSITION_TYPE_SELL) > 0; ++r)
            {
               BSC_CloseAllByType(POSITION_TYPE_SELL);
               BSC_RetrySleep();
            }
            // Early exit (not spike counter fill): delete BuyStops
            BSC_DeleteBuyStops();
            BSC_SetState(RESETTING);
            return;
         }
      }
   }

   // Keep BuyStop count synced (repair missing if still SELL active)
   const int bs = BSC_CountPendings(ORDER_TYPE_BUY_STOP);
   if(bs > BuyStopCount)
   {
      // never keep a 4th — delete extras by deleting all and recreating
      if(g_sellTicket > 0 && PositionSelectByTicket(g_sellTicket))
      {
         const double lot = PositionGetDouble(POSITION_VOLUME);
         const double lvl = PositionGetDouble(POSITION_SL);
         BSC_PlaceBuyStops((lvl > 0.0 ? lvl : g_sharedLevel), lot);
      }
   }
   else if(bs == 0 && g_sharedLevel > 0.0)
   {
      // Recreate fresh set if wiped unexpectedly while SELL still active
      double lot = g_currentLot;
      if(g_sellTicket > 0 && PositionSelectByTicket(g_sellTicket))
         lot = PositionGetDouble(POSITION_VOLUME);
      lot = BSC_ResolveExecutableLot(ORDER_TYPE_BUY_STOP, g_sharedLevel);
      if(lot > 0.0)
         BSC_PlaceBuyStops(g_sharedLevel, lot);
   }

   BSC_TrailSharedLevel();
}

//======================================================================
// BUY_ACTIVE (spec §11)
//======================================================================
void BSC_OnBuyActive()
{
   // No SELL while BUY active
   if(BSC_CountPositions(POSITION_TYPE_SELL) > 0)
   {
      BSC_CloseAllByType(POSITION_TYPE_SELL);
      BSC_DeleteBuyStops();
   }

   // Ensure unfilled BuyStops are gone
   if(BSC_CountPendings(ORDER_TYPE_BUY_STOP) > 0)
      BSC_DeleteBuyStops();

   if(BSC_CountPositions(POSITION_TYPE_BUY) == 0)
   {
      Print("BSC BUY flat → reset");
      BSC_SetState(RESETTING);
      return;
   }

   // Confirmed Red candle close (shift 1)
   if(!BSC_IsRed(1))
      return;

   const datetime exitBar = BSC_BarTime(1);
   if(exitBar == 0 || exitBar == g_lastBuyExitBar)
      return;

   PrintFormat("BSC BUY EXIT confirmed Red bar=%s — close all BUY",
               TimeToString(exitBar, TIME_DATE|TIME_MINUTES));
   g_lastBuyExitBar = exitBar;

   BSC_CloseAllByType(POSITION_TYPE_BUY);
   for(int r = 0; r < MaxRetries && BSC_CountPositions(POSITION_TYPE_BUY) > 0; ++r)
   {
      BSC_CloseAllByType(POSITION_TYPE_BUY);
      BSC_RetrySleep();
   }
   BSC_DeleteAllPendings();
   BSC_SetState(RESETTING);
}

//+------------------------------------------------------------------+
