//+------------------------------------------------------------------+
//| CBR_Risk.mqh                                                     |
//| Smart risk tiers: start 50%, -5% per tier, dynamic lot/entries    |
//+------------------------------------------------------------------+
#property copyright "Mark Moslares"
#ifndef CBR_RISK_MQH
#define CBR_RISK_MQH

#include "CBR_Utils.mqh"

struct CBRRiskPlan
{
   double riskPercent;     // max risk room for emergency/stop sizing
   double lot;             // computed trade volume
   int    maxEntries;      // allowed pending/entry intensity for tier
   int    tierIndex;       // 0-based
};

//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
double CBR_TierRiskPercent(const int tier)
{
   // Start 50%, step down 5% per tier, floor 15%
   double risk = 50.0 - (tier * 5.0);
   if(risk < 15.0)
      risk = 15.0;
   return risk;
}

//+------------------------------------------------------------------+
int CBR_TierMaxEntries(const int tier)
{
   // Tier0-1: 1 entry/position focus; then grow
   if(tier <= 1) return 1;
   if(tier == 2) return 2;
   if(tier == 3) return 2;
   if(tier == 4) return 3;
   if(tier == 5) return 3;
   if(tier == 6) return 4;
   return 5;
}

//+------------------------------------------------------------------+
double CBR_TierLotSteps(const int tier, const double lotStep)
{
   // Base 1 step, +1 step each tier (Baloch-like growth feel)
   const double steps = 1.0 + (double)tier;
   return steps * lotStep;
}

//+------------------------------------------------------------------+
CBRRiskPlan CBR_BuildRiskPlan(const string symbol,
                              const double emergencyStopDistance,
                              const ENUM_ORDER_TYPE orderTypeForMargin,
                              const double refPrice)
{
   CBRRiskPlan plan;
   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   plan.tierIndex   = CBR_TierIndex(equity);
   plan.riskPercent = CBR_TierRiskPercent(plan.tierIndex);
   plan.maxEntries  = CBR_TierMaxEntries(plan.tierIndex);

   const double vmin  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   const double vstep = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   const double step  = (vstep > 0.0 ? vstep : vmin);

   // Tier lot target from step ladder
   double lotByTier = CBR_NormalizeVolume(symbol, CBR_TierLotSteps(plan.tierIndex, step));

   // Risk-based lot from emergency stop distance
   const double riskMoney = equity * (plan.riskPercent / 100.0);
   double lotByRisk = CBR_LotForRiskMoney(symbol, riskMoney, emergencyStopDistance);

   // Use the more conservative of tier-ladder and risk-money when stop known;
   // for tiny accounts allow at least min lot if risk room is high.
   double lot = lotByTiers;
   if(emergencyStopDistance > 0.0)
   {
      // Prefer risk-based, but never below min; also never above margin-safe
      lot = MathMin(lotByTiers, lotByRisk);
      if(lot < vmin)
         lot = vmin;
      // If high risk% tier and risk-based allows more than tier base, allow up to risk-based
      // while still capped by max entries philosophy (lot only here)
      if(plan.riskPercent >= 40.0)
         lot = MathMax(lotByTiers, MathMin(lotByRisk, lotByTiers * 2.0));
   }

   const double maxMarginLot = CBR_MaxLotByMargin(symbol, refPrice, orderTypeForMargin, 0.70);
   lot = MathMin(lot, maxMarginLot);
   plan.lot = CBR_NormalizeVolume(symbol, lot);
   if(plan.lot < vmin)
      plan.lot = vmin;

   return plan;
}

#endif // CBR_RISK_MQH
