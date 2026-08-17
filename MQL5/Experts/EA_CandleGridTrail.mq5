//+------------------------------------------------------------------+
//| EA_CandleGridTrail.mq5                                           |
//| Candle Open Grid + Trail v1.00                                   |
//|                                                                  |
//| Same Inputs in Strategy Tester and live. No tester-only logic.   |
//| Open 4400, grid 0.2: BUY 4400.2/4400.4... SELL 4399.8/4399.6...  |
//| No entry at candle open. Market only. No pending.                |
//| Trail = current price -/+ InpTrailDistance.                      |
//| New candle: new grid from new open; old positions keep trailing. |
//| Lot = InpLot fixed.                                              |
//+------------------------------------------------------------------+
#property copyright "Mark Moslares"
#property link      "https://github.com/markazetro1123-cpu/mark-moslares"
#property version   "1.00"
#property description "CandleGridTrail v1.00: ±grid from candle open, market only, trail from price"

#include <Trade/Trade.mqh>

input group "=== Tester = Live (same values) ==="
input double   InpGridStep           = 0.2;    // Grid step (price). Tester and live.
input double   InpTrailDistance      = 0.3;    // Trail from current price. Tester and live.
input double   InpLot                = 0.01;   // Fixed lot. Tester and live.

input group "=== Broker ==="
input long     InpMagic              = 260817; // Magic number
input int      InpSlippagePoints     = 40;     // Deviation points

input group "=== Runtime ==="
input bool     InpShowComment        = true;   // On-chart status
input bool     InpPrintLogs          = true;   // Print logs

const int    CGT_SEND_PER_TICK = 5;
const string CGT_PREFIX        = "CGT";

CTrade   g_trade;
string   g_symbol;
bool     g_ready;
string   g_last_log;
datetime g_bar_time;
double   g_candle_open;
int      g_next_buy_n;
int      g_next_sell_n;

void CGT_Log(const string message)
{
   if(!InpPrintLogs)
      return;
   if(message == g_last_log)
      return;
   g_last_log = message;
   Print("[GridTrail] ", message);
}

double CGT_Point()
{
   double point = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   if(point <= 0.0)
      point = _Point;
   return point;
}

int CGT_Digits()
{
   return (int)SymbolInfoInteger(g_symbol, SYMBOL_DIGITS);
}

double CGT_NormPrice(const double price)
{
   return NormalizeDouble(price, CGT_Digits());
}

double CGT_GridStep()
{
   return InpGridStep;
}

double CGT_TrailDistance()
{
   return InpTrailDistance;
}

double CGT_Lot()
{
   return InpLot;
}

double CGT_NormVolume(double volume)
{
   double vmin  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   double vmax  = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MAX);
   double vstep = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   if(vstep <= 0.0)
      vstep = 0.01;
   if(vmin <= 0.0)
      vmin = 0.01;

   volume = MathFloor(volume / vstep + 1e-12) * vstep;
   if(volume < vmin)
      volume = vmin;
   if(vmax > 0.0 && volume > vmax)
      volume = vmax;

   int digits = 2;
   if(vstep < 0.01)
      digits = 3;
   if(vstep >= 1.0)
      digits = 0;
   return NormalizeDouble(volume, digits);
}

void CGT_PrepareTrade()
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

double CGT_StopsDistance()
{
   int stops  = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_STOPS_LEVEL);
   int freeze = (int)SymbolInfoInteger(g_symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   int level  = stops;
   if(freeze > level)
      level = freeze;
   return (double)level * CGT_Point();
}

bool CGT_TradeAllowed()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;
   if(SymbolInfoInteger(g_symbol, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
      return false;
   return true;
}

bool CGT_IsOurs(const ulong ticket)
{
   if(ticket == 0 || !PositionSelectByTicket(ticket))
      return false;
   if(PositionGetString(POSITION_SYMBOL) != g_symbol)
      return false;
   if((long)PositionGetInteger(POSITION_MAGIC) != InpMagic)
      return false;
   return true;
}

int CGT_KillPendings()
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
      CGT_Log("Deleted " + IntegerToString(killed) + " pending (market-only)");
   return killed;
}

double CGT_BuyLevel(const int n)
{
   return CGT_NormPrice(g_candle_open + n * CGT_GridStep());
}

double CGT_SellLevel(const int n)
{
   return CGT_NormPrice(g_candle_open - n * CGT_GridStep());
}

bool CGT_SendMarket(const int dir)
{
   CGT_KillPendings();
   CGT_PrepareTrade();

   const double lot = CGT_NormVolume(CGT_Lot());
   bool sent = false;
   if(dir > 0)
      sent = g_trade.Buy(lot, g_symbol, 0.0, 0.0, 0.0, CGT_PREFIX);
   else
      sent = g_trade.Sell(lot, g_symbol, 0.0, 0.0, 0.0, CGT_PREFIX);

   CGT_KillPendings();

   if(!sent)
   {
      CGT_Log("Market send failed dir=" + IntegerToString(dir) +
              " err=" + IntegerToString(GetLastError()) +
              " ret=" + IntegerToString((int)g_trade.ResultRetcode()));
      return false;
   }
   return true;
}

void CGT_FillGrid()
{
   if(!g_ready || !CGT_TradeAllowed())
      return;
   if(g_candle_open <= 0.0 || CGT_GridStep() <= 0.0)
      return;

   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   if(ask <= 0.0 || bid <= 0.0)
      return;

   int sent = 0;

   while(sent < CGT_SEND_PER_TICK)
   {
      const double level = CGT_BuyLevel(g_next_buy_n);
      if(ask < level)
         break;
      if(!CGT_SendMarket(1))
         break;
      CGT_Log("BUY market n=" + IntegerToString(g_next_buy_n) +
              " level=" + DoubleToString(level, CGT_Digits()) +
              " ask=" + DoubleToString(ask, CGT_Digits()));
      g_next_buy_n++;
      sent++;
   }

   while(sent < CGT_SEND_PER_TICK)
   {
      const double level = CGT_SellLevel(g_next_sell_n);
      if(bid > level)
         break;
      if(!CGT_SendMarket(-1))
         break;
      CGT_Log("SELL market n=" + IntegerToString(g_next_sell_n) +
              " level=" + DoubleToString(level, CGT_Digits()) +
              " bid=" + DoubleToString(bid, CGT_Digits()));
      g_next_sell_n++;
      sent++;
   }
}

void CGT_TrailAll()
{
   const double trail = CGT_TrailDistance();
   if(trail <= 0.0)
      return;

   const double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   const double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   const double minDist = CGT_StopsDistance();
   const double dist = MathMax(trail, minDist);

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong ticket = PositionGetTicket(i);
      if(!CGT_IsOurs(ticket))
         continue;

      const long   type = PositionGetInteger(POSITION_TYPE);
      const double sl   = PositionGetDouble(POSITION_SL);
      const double tp   = PositionGetDouble(POSITION_TP);
      double newSL = sl;

      if(type == POSITION_TYPE_BUY)
      {
         newSL = CGT_NormPrice(bid - dist);
         if(newSL >= bid)
            continue;
         if(sl != 0.0 && newSL <= sl)
            continue;
      }
      else
      {
         newSL = CGT_NormPrice(ask + dist);
         if(newSL <= ask)
            continue;
         if(sl != 0.0 && newSL >= sl)
            continue;
      }

      if(MathAbs(newSL - sl) < CGT_Point())
         continue;
      if(!g_trade.PositionModify(ticket, newSL, tp))
         CGT_Log("Trail modify failed ticket=" + IntegerToString((long)ticket) +
                 " err=" + IntegerToString(GetLastError()));
   }
}

void CGT_OnNewCandle(const double openPrice)
{
   g_candle_open = openPrice;
   g_next_buy_n  = 1;
   g_next_sell_n = 1;
   CGT_Log("New candle open=" + DoubleToString(g_candle_open, CGT_Digits()) +
           " next BUY=" + DoubleToString(CGT_BuyLevel(1), CGT_Digits()) +
           " next SELL=" + DoubleToString(CGT_SellLevel(1), CGT_Digits()) +
           " (old positions keep trailing)");
}

void CGT_UpdateComment()
{
   if(!InpShowComment)
      return;

   Comment(
      "Candle Grid Trail v1.00  (tester Inputs = live Inputs)\n",
      "symbol: ", g_symbol, "\n",
      "open: ", DoubleToString(g_candle_open, CGT_Digits()), "\n",
      "grid: ", DoubleToString(CGT_GridStep(), CGT_Digits()),
      "  trail: ", DoubleToString(CGT_TrailDistance(), CGT_Digits()),
      "  lot: ", DoubleToString(CGT_Lot(), 2), "\n",
      "next BUY: ", DoubleToString(CGT_BuyLevel(g_next_buy_n), CGT_Digits()),
      "  next SELL: ", DoubleToString(CGT_SellLevel(g_next_sell_n), CGT_Digits()), "\n",
      "buy steps done: ", IntegerToString(g_next_buy_n - 1),
      "  sell steps done: ", IntegerToString(g_next_sell_n - 1)
   );
}

int OnInit()
{
   g_symbol        = _Symbol;
   g_ready         = false;
   g_last_log      = "";
   g_bar_time      = 0;
   g_candle_open   = 0.0;
   g_next_buy_n    = 1;
   g_next_sell_n   = 1;

   if(InpGridStep <= 0.0)
   {
      Print("[GridTrail] InpGridStep must be > 0");
      return INIT_FAILED;
   }
   if(InpTrailDistance <= 0.0)
   {
      Print("[GridTrail] InpTrailDistance must be > 0");
      return INIT_FAILED;
   }
   if(InpLot <= 0.0)
   {
      Print("[GridTrail] InpLot must be > 0");
      return INIT_FAILED;
   }

   g_ready = true;
   CGT_PrepareTrade();

   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_NETTING)
      CGT_Log("Warning: netting account cannot hold buy+sell together. Use hedge.");

   CGT_Log("Ready " + g_symbol +
           " grid=" + DoubleToString(CGT_GridStep(), CGT_Digits()) +
           " trail=" + DoubleToString(CGT_TrailDistance(), CGT_Digits()) +
           " lot=" + DoubleToString(CGT_Lot(), 2) +
           " (same Inputs in tester and live)");
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

   CGT_PrepareTrade();
   CGT_KillPendings();
   CGT_TrailAll();

   double opens[];
   ArraySetAsSeries(opens, true);
   if(CopyOpen(g_symbol, PERIOD_CURRENT, 0, 1, opens) < 1)
      return;

   const datetime barTime = iTime(g_symbol, PERIOD_CURRENT, 0);
   if(barTime <= 0)
      return;

   if(g_bar_time == 0)
   {
      g_bar_time = barTime;
      CGT_OnNewCandle(opens[0]);
   }
   else if(barTime != g_bar_time)
   {
      g_bar_time = barTime;
      CGT_OnNewCandle(opens[0]);
   }

   CGT_FillGrid();
   CGT_UpdateComment();
}
