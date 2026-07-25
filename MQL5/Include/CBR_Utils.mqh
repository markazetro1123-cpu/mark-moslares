//+------------------------------------------------------------------+
//| CBR_Utils.mqh                                                    |
//| Broker-safe helpers for Candle-Bias Trailing Scalper             |
//+------------------------------------------------------------------+
#property copyright "Mark Moslares"
#ifndef CBR_UTILS_MQH
#define CBR_UTILS_MQH

#include <Trade/Trade.mqh>
#include <Trade/OrderInfo.mqh>
#include <Trade/PositionInfo.mqh>

//+------------------------------------------------------------------+
double CBR_Point(const string symbol)
{
   double p = SymbolInfoDouble(symbol, SYMBOL_POINT);
   return (p > 0.0 ? p : _Point);
}

//+------------------------------------------------------------------+
int CBR_Digits(const string symbol)
{
   return (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
}

//+------------------------------------------------------------------+
double CBR_NormalizePrice(const string symbol, double price)
{
   return NormalizeDouble(price, CBR_Digits(symbol));
}

//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
double CBR_StopsLevelDistance(const string symbol)
{
   const int stops = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL);
   const int freeze = (int)SymbolInfoInteger(symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   const int lvl = MathMax(stops, freeze);
   return lvl * CBR_Point(symbol);
}

//+------------------------------------------------------------------+
bool CBR_IsTradeAllowed(const string symbol)
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      return false;
   if(!SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE))
      return false;
   long mode = SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED)
      return false;
   return true;
}

//+------------------------------------------------------------------+
int CBR_CountPositions(const string symbol, const long magic)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic)
         continue;
      count++;
   }
   return count;
}

//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
int CBR_CountPending(const string symbol, const long magic)
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; --i)
   {
      const ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(!OrderSelect(ticket))
         continue;
      if(OrderGetString(ORDER_SYMBOL) != symbol)
         continue;
      if(OrderGetInteger(ORDER_MAGIC) != magic)
         continue;
      const long t = OrderGetInteger(ORDER_TYPE);
      if(t == ORDER_TYPE_BUY_STOP || t == ORDER_TYPE_SELL_STOP ||
         t == ORDER_TYPE_BUY_LIMIT || t == ORDER_TYPE_SELL_LIMIT ||
         t == ORDER_TYPE_BUY_STOP_LIMIT || t == ORDER_TYPE_SELL_STOP_LIMIT)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
double CBR_LotForRiskMoney(const string symbol, const double riskMoney, const double stopDistance)
{
   const double lossPerLot = CBR_LossPerLotForDistance(symbol, stopDistance);
   if(lossPerLot <= 0.0 || riskMoney <= 0.0)
      return SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   return CBR_NormalizeVolume(symbol, riskMoney / lossPerLot);
}

//+------------------------------------------------------------------+
double CBR_MaxLotByMargin(const string symbol, const double price, const ENUM_ORDER_TYPE type, const double maxMarginShare = 0.8)
{
   const double free = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(free <= 0.0)
      return SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);

   double marginOne = 0.0;
   if(!OrderCalcMargin(type, symbol, 1.0, price, marginOne) || marginOne <= 0.0)
   {
      // fallback rough estimate using min lot scale
      double marginMin = 0.0;
      const double vmin = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
      if(!OrderCalcMargin(type, symbol, vmin, price, marginMin) || marginMin <= 0.0)
         return vmin;
      marginOne = marginMin / vmin;
   }

   const double affordable = (free * maxMarginShare) / marginOne;
   return CBR_NormalizeVolume(symbol, affordable);
}

#endif // CBR_UTILS_MQH
