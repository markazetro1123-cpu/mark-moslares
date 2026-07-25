//+------------------------------------------------------------------+
//| TradeHelpers.mqh                                                 |
//| Shared helpers for position sizing, filters, and order ops       |
//+------------------------------------------------------------------+
#property copyright "Mark Moslares"
#property strict

#include <Trade/Trade.mqh>

//+------------------------------------------------------------------+
//| Count open positions for this symbol + magic                     |
//+------------------------------------------------------------------+
int CountPositions(const string symbol, const long magic)
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(!PositionSelectByTicket(ticket))
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
//| Normalize volume to broker constraints                           |
//+------------------------------------------------------------------+
double NormalizeVolume(const string symbol, double volume)
{
   const double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   const double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   const double stepLot = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);

   if(stepLot <= 0.0)
      return minLot;

   volume = MathFloor(volume / stepLot) * stepLot;
   volume = MathMax(minLot, MathMin(maxLot, volume));
   return NormalizeDouble(volume, 2);
}

//+------------------------------------------------------------------+
//| Risk-based lot size from stop distance in price                  |
//+------------------------------------------------------------------+
double CalcLotByRisk(const string symbol, const double riskPercent, const double stopDistance)
{
   if(riskPercent <= 0.0 || stopDistance <= 0.0)
      return SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);

   const double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   const double riskMoney = balance * (riskPercent / 100.0);
   const double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   const double tickValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE);

   if(tickSize <= 0.0 || tickValue <= 0.0)
      return SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);

   const double lossPerLot = (stopDistance / tickSize) * tickValue;
   if(lossPerLot <= 0.0)
      return SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);

   return NormalizeVolume(symbol, riskMoney / lossPerLot);
}

//+------------------------------------------------------------------+
//| Current spread in points                                         |
//+------------------------------------------------------------------+
double CurrentSpreadPoints(const string symbol)
{
   const double ask   = SymbolInfoDouble(symbol, SYMBOL_ASK);
   const double bid   = SymbolInfoDouble(symbol, SYMBOL_BID);
   const double point = SymbolInfoDouble(symbol, SYMBOL_POINT);
   if(point <= 0.0)
      return 999999.0;
   return (ask - bid) / point;
}

//+------------------------------------------------------------------+
//| Trading session filter (broker server time)                      |
//+------------------------------------------------------------------+
bool IsWithinTradingHours(const int startHour, const int endHour)
{
   MqlDateTime now;
   TimeToStruct(TimeCurrent(), now);
   const int hour = now.hour;

   if(startHour == endHour)
      return true; // 24h

   if(startHour < endHour)
      return (hour >= startHour && hour < endHour);

   // Overnight window, e.g. 22 -> 6
   return (hour >= startHour || hour < endHour);
}

//+------------------------------------------------------------------+
//| Apply trailing stop to open positions                            |
//+------------------------------------------------------------------+
void ApplyTrailingStop(CTrade &trade,
                       const string symbol,
                       const long magic,
                       const double trailPoints,
                       const double trailStepPoints)
{
   if(trailPoints <= 0.0)
      return;

   const double point    = SymbolInfoDouble(symbol, SYMBOL_POINT);
   const int    digits   = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   const double trailDist = trailPoints * point;
   const double trailStep = trailStepPoints * point;

   for(int i = PositionsTotal() - 1; i >= 0; --i)
   {
      const ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket))
         continue;
      if(PositionGetString(POSITION_SYMBOL) != symbol)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) != magic)
         continue;

      const long   type   = PositionGetInteger(POSITION_TYPE);
      const double sl     = PositionGetDouble(POSITION_SL);
      const double tp     = PositionGetDouble(POSITION_TP);
      const double bid    = SymbolInfoDouble(symbol, SYMBOL_BID);
      const double ask    = SymbolInfoDouble(symbol, SYMBOL_ASK);

      if(type == POSITION_TYPE_BUY)
      {
         const double newSL = NormalizeDouble(bid - trailDist, digits);
         if(bid - sl >= trailDist + trailStep || sl == 0.0)
         {
            if(newSL > sl || sl == 0.0)
               trade.PositionModify(ticket, newSL, tp);
         }
      }
      else if(type == POSITION_TYPE_SELL)
      {
         const double newSL = NormalizeDouble(ask + trailDist, digits);
         if(sl - ask >= trailDist + trailStep || sl == 0.0)
         {
            if(newSL < sl || sl == 0.0)
               trade.PositionModify(ticket, newSL, tp);
         }
      }
   }
}
