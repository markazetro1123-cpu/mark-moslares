//+------------------------------------------------------------------+
//| EA_BalochPulse.mq5                                               |
//| ARCHITECTURE v2.50 — rules enforced inside engines               |
//|                                                                  |
//| SINGLE FILE ONLY.                                                |
//|                                                                  |
//| LOCKED RULES (not input knobs):                                  |
//|  R1  NY-London session only for NEW entries                      |
//|  R2  Hard blackout 20:30-20:40 & 21:30-21:40 local               |
//|  R3  Block high-impact USD + FOMC                                |
//|  R4  Adaptive tick imbalance (no fixed 30 ticks)                 |
//|  R5  Candle memory must agree                                    |
//|  R6  Impulse -> small pullback -> enter                          |
//|  R7  Risk Manager decides lot + entry count                      |
//|  R8  $30-$50 can open 2-3 when clean                             |
//|  R9  Max 15 entries hard cap                                     |
//|  R10 Same-price burst (one price band / one shot)                |
//|  R11 No martingale (same lot per cycle)                          |
//|  R12 Smart self-exit is main exit                                |
//|  R13 No spread filter                                            |
//|  R14 XAUUSD + US30 same logic                                    |
//|  R15 Engines always active + on-chart rule monitor               |
//+------------------------------------------------------------------+
#property copyright "Mark Moslares"
#property link      "https://github.com/markazetro1123-cpu/mark-moslares"
#property version   "2.50"
#property description "BalochPulse ARCH v2.50 — enforced rules + live rule monitor"

#include <Trade/Trade.mqh>

//======================================================================
// MINIMAL INPUTS ONLY
//======================================================================
input group "=== Account / Broker ==="
input long   InpMagic              = 260726;
input double InpRiskPercent        = 2.0;
input double InpMinLot             = 0.01;
input double InpMaxLotCap          = 1.00;
input int    InpSlippagePoints     = 40;
input bool   InpAllowBuy           = true;
input bool   InpAllowSell          = true;

input group "=== Session Clock (PH default) ==="
input int    InpSessionTZOffsetHrs = 8;
input int    InpSessionStartHour   = 20;
input int    InpSessionStartMinute = 0;
input int    InpSessionEndHour     = 5;
input int    InpSessionEndMinute   = 0;

input group "=== Runtime ==="
input bool   InpPrintLogs          = true;

//======================================================================
// LOCKED CONSTANTS
//======================================================================
const int    BP_MAX_ENTRIES        = 15;
const int    BP_TICK_CAP           = 1200;
const int    BP_MIN_TICKS          = 6;
const int    BP_WIN_MIN            = 2;
const int    BP_WIN_MAX            = 60;
const int    BP_SETUP_EXPIRE       = 45;
const int    BP_COOLDOWN           = 3;
const int    BP_NEWS_BUF           = 8;
const int    BP_FOMC_BUF           = 45;
const int    BP_MEM                = 12;
const double BP_DD_DEF             = 1.5;
const double BP_DD_LOCK            = 3.0;
const int    BP_LOSS_DEF           = 2;
const int    BP_LOSS_LOCK          = 4;

//======================================================================
enum ENUM_BP_STATE
{
   BP_IDLE=0, BP_BIAS_DETECT, BP_IMPULSE, BP_PULLBACK, BP_BURST, BP_MANAGE, BP_COOLDOWN
};
enum ENUM_BP_MODE { BP_AGG=0, BP_NORMAL, BP_DEF, BP_LOCK };
enum ENUM_BP_BIAS { BP_NONE=0, BP_BUY=1, BP_SELL=-1 };

struct TickSample { long time_ms; double mid; int dir; };
struct AdaptiveSignal
{
   bool valid; double upBias, downBias, netMove, tps, mps, thr, strength;
   int ticksUsed, windowSec; ENUM_BP_BIAS bias;
};
struct TradeMemory { bool used, win; double pnl; datetime time; };

//======================================================================
CTrade trade;
string g_symbol; bool g_ok=false, g_gold=false, g_us30=false;

TickSample g_ticks[]; int g_cap=0, g_head=0, g_count=0; double g_lastMid=0;

ENUM_BP_STATE g_state=BP_IDLE;
ENUM_BP_BIAS  g_bias=BP_NONE;
ENUM_BP_MODE  g_mode=BP_NORMAL;

datetime g_setupTime=0, g_cooldownUntil=0;
double g_impStart=0, g_impExtreme=0, g_impMove=0, g_pbExtreme=0;
bool   g_pbSeen=false;

double g_firstFill=0, g_cycleLot=0, g_peakPnl=0;
int g_lossStreak=0, g_winStreak=0, g_memPos=0;
TradeMemory g_mem[];

datetime g_newsCheck=0; bool g_newsBlock=false; string g_newsReason="";
string g_rule="boot", g_lastLog="";
AdaptiveSignal g_lastSig;

//======================================================================
void BP_Log(const string m)
{
   if(!InpPrintLogs) return;
   if(m==g_lastLog) return;
   g_lastLog=m;
   Print("[BalochPulse] ", m);
}
double BP_Point(){ double p=SymbolInfoDouble(g_symbol,SYMBOL_POINT); return p>0?p:_Point; }
int    BP_Digits(){ return (int)SymbolInfoInteger(g_symbol,SYMBOL_DIGITS); }
double BP_NormP(const double p){ return NormalizeDouble(p,BP_Digits()); }
double BP_ClampD(const double v,const double a,const double b){ return MathMax(a,MathMin(b,v)); }
int    BP_ClampI(const int v,const int a,const int b){ return (int)MathMax(a,MathMin(b,v)); }

double BP_NormV(double vol)
{
   double vmin=SymbolInfoDouble(g_symbol,SYMBOL_VOLUME_MIN);
   double vmax=SymbolInfoDouble(g_symbol,SYMBOL_VOLUME_MAX);
   double vs=SymbolInfoDouble(g_symbol,SYMBOL_VOLUME_STEP);
   if(vs<=0) return vmin;
   vol=MathFloor(vol/vs+1e-12)*vs;
   vol=MathMax(vmin,MathMin(vmax,vol));
   vol=MathMax(InpMinLot,MathMin(InpMaxLotCap,vol));
   int d=2; if(vs<0.01)d=3; if(vs>=1)d=0;
   return NormalizeDouble(vol,d);
}
bool BP_Fill(ENUM_ORDER_TYPE_FILLING &f)
{
   int m=(int)SymbolInfoInteger(g_symbol,SYMBOL_FILLING_MODE);
   if((m&SYMBOL_FILLING_IOC)==SYMBOL_FILLING_IOC){f=ORDER_FILLING_IOC;return true;}
   if((m&SYMBOL_FILLING_FOK)==SYMBOL_FILLING_FOK){f=ORDER_FILLING_FOK;return true;}
   f=ORDER_FILLING_RETURN; return true;
}
double BP_Stops(){ return MathMax((int)SymbolInfoInteger(g_symbol,SYMBOL_TRADE_STOPS_LEVEL),(int)SymbolInfoInteger(g_symbol,SYMBOL_TRADE_FREEZE_LEVEL))*BP_Point(); }
bool BP_TradeOk()
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) return false;
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED)) return false;
   if(SymbolInfoInteger(g_symbol,SYMBOL_TRADE_MODE)==SYMBOL_TRADE_MODE_DISABLED) return false;
   return true;
}
double BP_Mid()
{
   double b=SymbolInfoDouble(g_symbol,SYMBOL_BID), a=SymbolInfoDouble(g_symbol,SYMBOL_ASK);
   if(b<=0||a<=0) return 0;
   return (a+b)*0.5;
}
double BP_Unit()
{
   if(g_us30) return MathMax(0.8, 80.0*BP_Point());
   return MathMax(0.08, 80.0*BP_Point());
}
double BP_SameBand()
{
   // R10: tiny slippage only
   if(g_us30) return MathMax(1.5, 120.0*BP_Point());
   return MathMax(0.15, 120.0*BP_Point());
}
double BP_EmergSL()
{
   if(g_us30) return MathMax(30.0, 1000.0*BP_Point());
   return MathMax(4.0, 1000.0*BP_Point());
}
double BP_MinSecure()
{
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   if(eq<50) return MathMax(0.10, eq*0.0025);
   if(eq<200) return MathMax(0.25, eq*0.0018);
   return MathMax(0.60, eq*0.0012);
}
int BP_LocalMin()
{
   datetime tz=TimeGMT()+InpSessionTZOffsetHrs*3600;
   MqlDateTime dt; TimeToStruct(tz,dt);
   return dt.hour*60+dt.min;
}
bool BP_Win(const int now,const int a,const int b)
{
   if(a==b) return false;
   if(a<b) return (now>=a && now<b);
   return (now>=a || now<b);
}
string BP_Up(string s){ StringToUpper(s); return s; }
string BP_ModeName(const ENUM_BP_MODE m)
{
   if(m==BP_AGG) return "AGGRESSIVE";
   if(m==BP_DEF) return "DEFENSIVE";
   if(m==BP_LOCK) return "LOCKDOWN";
   return "NORMAL";
}
string BP_StateName(const ENUM_BP_STATE s)
{
   switch(s)
   {
      case BP_BIAS_DETECT: return "BIAS_DETECT";
      case BP_IMPULSE: return "IMPULSE";
      case BP_PULLBACK: return "PULLBACK";
      case BP_BURST: return "BURST";
      case BP_MANAGE: return "MANAGE";
      case BP_COOLDOWN: return "COOLDOWN";
      default: return "IDLE";
   }
}

//======================================================================
// SYMBOL (R14)
//======================================================================
bool BP_IsGold(const string s){ string u=BP_Up(s); return (StringFind(u,"XAUUSD")>=0 || (StringFind(u,"GOLD")>=0 && StringFind(u,"GOLDF")<0)); }
bool BP_IsUS30(const string s)
{
   string u=BP_Up(s);
   return (StringFind(u,"US30")>=0 || StringFind(u,"DJ30")>=0 || StringFind(u,"DJIA")>=0 ||
           StringFind(u,"WALLSTREET30")>=0 || StringFind(u,"WST30")>=0 || StringFind(u,"DOWJONES")>=0);
}
bool BP_Validate()
{
   g_symbol=_Symbol; g_gold=BP_IsGold(g_symbol); g_us30=BP_IsUS30(g_symbol); g_ok=(g_gold||g_us30);
   if(!g_ok){ BP_Log("RULE FAIL R14 unsupported symbol "+g_symbol); return false; }
   return true;
}

//======================================================================
// R1 SESSION
//======================================================================
bool BP_SessionOK()
{
   int now=BP_LocalMin();
   int a=InpSessionStartHour*60+InpSessionStartMinute;
   int b=InpSessionEndHour*60+InpSessionEndMinute;
   return BP_Win(now,a,b);
}

//======================================================================
// R2 + R3 NEWS
//======================================================================
bool BP_HardBlackout(string &why)
{
   int now=BP_LocalMin();
   if(BP_Win(now,20*60+30,20*60+40)){ why="R2 blackout 20:30-20:40"; return true; }
   if(BP_Win(now,21*60+30,21*60+40)){ why="R2 blackout 21:30-21:40"; return true; }
   return false;
}
bool BP_IsFOMC(const string t)
{
   string u=t; StringToUpper(u);
   return (StringFind(u,"FOMC")>=0 || StringFind(u,"FEDERAL FUNDS")>=0 || StringFind(u,"FED RATE")>=0 ||
           StringFind(u,"INTEREST RATE DECISION")>=0 || StringFind(u,"FEDERAL OPEN MARKET")>=0 ||
           StringFind(u,"MONETARY POLICY STATEMENT")>=0);
}
bool BP_CalendarBlock(string &why)
{
   if(TimeCurrent()-g_newsCheck<15 && g_newsCheck>0){ why=g_newsReason; return g_newsBlock; }
   g_newsCheck=TimeCurrent(); g_newsBlock=false; g_newsReason="";
   datetime now=TimeTradeServer();
   datetime from=now-BP_FOMC_BUF*60, to=now+BP_FOMC_BUF*60;
   MqlCalendarValue vals[];
   int n=CalendarValueHistory(vals,from,to,"US",NULL);
   if(n<=0) n=CalendarValueHistory(vals,from,to,NULL,NULL);
   if(n<=0) return false;
   for(int i=0;i<n;i++)
   {
      MqlCalendarEvent ev; if(!CalendarEventById(vals[i].event_id,ev)) continue;
      MqlCalendarCountry co; string c="";
      if(CalendarCountryById(ev.country_id,co)) c=co.code;
      if(c!="" && c!="US") continue;
      bool fomc=BP_IsFOMC(ev.name);
      bool hi=(ev.importance==CALENDAR_IMPORTANCE_HIGH);
      if(!fomc && !hi) continue; // other news OK
      int buf=fomc?BP_FOMC_BUF:BP_NEWS_BUF;
      datetime et=vals[i].time;
      if(now>=et-buf*60 && now<=et+buf*60)
      {
         g_newsBlock=true;
         g_newsReason=(fomc?"R3 FOMC: ":"R3 USD-HIGH: ")+ev.name;
         why=g_newsReason; return true;
      }
   }
   return false;
}
bool BP_NewsBlocked(string &why)
{
   if(BP_HardBlackout(why)) return true;
   if(BP_CalendarBlock(why)) return true;
   return false;
}
bool BP_CanEntry(string &why)
{
   if(!BP_SessionOK()){ why="R1 outside NY-London"; return false; }
   if(BP_NewsBlocked(why)) return false;
   return true;
}

//======================================================================
// R4 ADAPTIVE TICK (+ tester synthesis so rules can execute)
//======================================================================
void BP_TickInit()
{
   g_cap=BP_TICK_CAP; ArrayResize(g_ticks,g_cap); g_head=0; g_count=0; g_lastMid=0;
}
void BP_PushOne(const double mid, const long tms)
{
   if(mid<=0) return;
   int dir=0;
   if(g_lastMid>0){ if(mid>g_lastMid) dir=1; else if(mid<g_lastMid) dir=-1; }
   g_lastMid=mid;
   g_ticks[g_head].time_ms=tms; g_ticks[g_head].mid=mid; g_ticks[g_head].dir=dir;
   g_head=(g_head+1)%g_cap; if(g_count<g_cap) g_count++;
}
void BP_PushTick()
{
   MqlTick t;
   if(SymbolInfoTick(g_symbol,t))
   {
      double mid=(t.bid+t.ask)*0.5;
      BP_PushOne(mid,(long)t.time_msc);
   }

   // In tester/sparse ticks: synthesize path from recent M1 so R4-R6 can run
   if(g_count<BP_MIN_TICKS || MQLInfoInteger(MQL_TESTER))
   {
      double c[]; ArraySetAsSeries(c,true);
      if(CopyClose(g_symbol,PERIOD_M1,0,6,c)>=6)
      {
         long base=(long)TimeCurrent()*1000;
         for(int i=5;i>=0;i--)
            BP_PushOne(c[i], base - (long)i*10000);
      }
   }
}
bool BP_GetTick(const int age, TickSample &out)
{
   if(age<0||age>=g_count) return false;
   int idx=g_head-1-age; while(idx<0) idx+=g_cap;
   out=g_ticks[idx]; return true;
}
AdaptiveSignal BP_Signal()
{
   AdaptiveSignal s; ZeroMemory(s); s.bias=BP_NONE;
   if(g_count<BP_MIN_TICKS) return s;
   TickSample n; if(!BP_GetTick(0,n)) return s;

   int ft=0; double ff=n.mid;
   for(int i=0;i<g_count;i++)
   {
      TickSample ts; if(!BP_GetTick(i,ts)) break;
      if(n.time_ms-ts.time_ms>3000) break;
      ft++; ff=ts.mid;
   }
   double tps=(ft>1?ft/3.0:0.5);
   double mps=MathAbs(n.mid-ff)/3.0;
   s.tps=tps; s.mps=mps;

   double target=16;
   if(tps>=8) target=3; else if(tps>=4) target=6; else if(tps>=2) target=10; else if(tps>=1) target=18; else target=35;
   double unit=BP_Unit();
   if(mps>unit*0.8) target*=0.75;
   if(mps<unit*0.12) target*=1.25;
   int win=BP_ClampI((int)MathRound(target),BP_WIN_MIN,BP_WIN_MAX);
   s.windowSec=win;

   long wms=(long)win*1000; int up=0,dn=0,used=0; double first=n.mid;
   for(int i=0;i<g_count;i++)
   {
      TickSample ts; if(!BP_GetTick(i,ts)) break;
      if(n.time_ms-ts.time_ms>wms) break;
      used++; if(ts.dir>0) up++; else if(ts.dir<0) dn++; first=ts.mid;
   }
   if(used<BP_MIN_TICKS) return s;
   int dirN=up+dn; if(dirN<=0) return s;
   s.ticksUsed=used; s.upBias=(double)up/dirN; s.downBias=(double)dn/dirN; s.netMove=n.mid-first;

   double thr=0.62; if(tps>=5) thr=0.55; else if(tps>=2.5) thr=0.58; else if(tps<1) thr=0.66;
   s.thr=thr;
   double minMove=unit*0.20;
   if(s.upBias>=thr && s.netMove>=minMove) s.bias=BP_BUY;
   else if(s.downBias>=thr && s.netMove<=-minMove) s.bias=BP_SELL;

   double imb=MathMax(s.upBias,s.downBias);
   double moveScore=BP_ClampD(MathAbs(s.netMove)/MathMax(unit,BP_Point()),0,2)/2.0;
   double imbScore=BP_ClampD((imb-0.50)/0.30,0,1);
   s.strength=BP_ClampD(0.55*imbScore+0.45*moveScore,0,1);
   s.valid=true;
   return s;
}

//======================================================================
// R5 CANDLE MEMORY
//======================================================================
bool BP_CandleOK(const ENUM_BP_BIAS bias)
{
   if(bias==BP_NONE) return false;
   double o[],c[],h[],l[];
   ArraySetAsSeries(o,true); ArraySetAsSeries(c,true); ArraySetAsSeries(h,true); ArraySetAsSeries(l,true);
   if(CopyOpen(g_symbol,PERIOD_CURRENT,0,3,o)<3) return false;
   if(CopyClose(g_symbol,PERIOD_CURRENT,0,3,c)<3) return false;
   if(CopyHigh(g_symbol,PERIOD_CURRENT,0,3,h)<3) return false;
   if(CopyLow(g_symbol,PERIOD_CURRENT,0,3,l)<3) return false;
   double body0=c[0]-o[0], body1=c[1]-o[1];
   double range1=MathMax(BP_Point(),h[1]-l[1]);
   double cp=(c[1]-l[1])/range1;
   if(bias==BP_BUY)
   {
      if(body1<-range1*0.70 && cp<0.22) return false;
      return (body1>=0 || body0>=0 || cp>=0.50);
   }
   if(body1>range1*0.70 && cp>0.78) return false;
   return (body1<=0 || body0<=0 || cp<=0.50);
}
bool BP_CandleThreat(const ENUM_BP_BIAS b)
{
   if(b==BP_NONE) return false;
   double o[],c[],h[],l[];
   ArraySetAsSeries(o,true); ArraySetAsSeries(c,true); ArraySetAsSeries(h,true); ArraySetAsSeries(l,true);
   if(CopyOpen(g_symbol,PERIOD_CURRENT,0,2,o)<2) return false;
   if(CopyClose(g_symbol,PERIOD_CURRENT,0,2,c)<2) return false;
   if(CopyHigh(g_symbol,PERIOD_CURRENT,0,2,h)<2) return false;
   if(CopyLow(g_symbol,PERIOD_CURRENT,0,2,l)<2) return false;
   double range=MathMax(BP_Point(),h[0]-l[0]); double body=c[0]-o[0];
   if(b==BP_BUY) return (body<-range*0.32);
   return (body>range*0.32);
}

//======================================================================
// POSITIONS
//======================================================================
int BP_Count()
{
   int n=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(t==0||!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=g_symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      n++;
   }
   return n;
}
ENUM_BP_BIAS BP_OpenBias()
{
   ENUM_BP_BIAS b=BP_NONE;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(t==0||!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=g_symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      long ty=PositionGetInteger(POSITION_TYPE);
      if(ty==POSITION_TYPE_BUY){ if(b==BP_SELL) return BP_NONE; b=BP_BUY; }
      else if(ty==POSITION_TYPE_SELL){ if(b==BP_BUY) return BP_NONE; b=BP_SELL; }
   }
   return b;
}
double BP_FloatPnl()
{
   double p=0;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(t==0||!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=g_symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      p+=PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
   }
   return p;
}
bool BP_CloseAll(const string why)
{
   bool ok=true;
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(t==0||!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=g_symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(!trade.PositionClose(t)) ok=false;
   }
   if(ok){ g_rule="R12 closed: "+why; BP_Log(g_rule); }
   return ok;
}
void BP_EnsureSL()
{
   double dist=MathMax(BP_EmergSL(), BP_Stops()+2*BP_Point());
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i); if(t==0||!PositionSelectByTicket(t)) continue;
      if(PositionGetString(POSITION_SYMBOL)!=g_symbol) continue;
      if((long)PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      if(PositionGetDouble(POSITION_SL)>0) continue;
      long ty=PositionGetInteger(POSITION_TYPE);
      double op=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=(ty==POSITION_TYPE_BUY)?BP_NormP(op-dist):BP_NormP(op+dist);
      trade.PositionModify(t,sl,PositionGetDouble(POSITION_TP));
   }
}

//======================================================================
// R7 RISK MANAGER CEO
//======================================================================
void BP_MemInit()
{
   ArrayResize(g_mem,BP_MEM);
   for(int i=0;i<BP_MEM;i++){ g_mem[i].used=false; g_mem[i].win=false; g_mem[i].pnl=0; g_mem[i].time=0; }
   g_memPos=0;
}
void BP_MemAdd(const double pnl)
{
   g_mem[g_memPos].used=true; g_mem[g_memPos].pnl=pnl; g_mem[g_memPos].win=(pnl>0); g_mem[g_memPos].time=TimeCurrent();
   g_memPos=(g_memPos+1)%BP_MEM;
   if(pnl>0){ g_winStreak++; g_lossStreak=0; }
   else if(pnl<0){ g_lossStreak++; g_winStreak=0; }
}
double BP_WR(int &n)
{
   int w=0; n=0;
   for(int i=0;i<BP_MEM;i++){ if(!g_mem[i].used) continue; n++; if(g_mem[i].win) w++; }
   if(n<=0) return 0.5; return (double)w/n;
}
double BP_LossPerLot(const double d)
{
   if(d<=0) return 0;
   double ts=SymbolInfoDouble(g_symbol,SYMBOL_TRADE_TICK_SIZE);
   double tv=SymbolInfoDouble(g_symbol,SYMBOL_TRADE_TICK_VALUE);
   if(ts<=0||tv<=0) return 0;
   return (d/ts)*tv;
}
double BP_MaxLot(const ENUM_ORDER_TYPE ty,const double px)
{
   double free=AccountInfoDouble(ACCOUNT_MARGIN_FREE), vmin=SymbolInfoDouble(g_symbol,SYMBOL_VOLUME_MIN);
   if(free<=0) return vmin;
   double m1=0;
   if(!OrderCalcMargin(ty,g_symbol,1.0,px,m1)||m1<=0)
   {
      double mm=0; if(!OrderCalcMargin(ty,g_symbol,vmin,px,mm)||mm<=0) return vmin; m1=mm/vmin;
   }
   return BP_NormV((free*0.65)/m1);
}

// R8 equity intelligence
int BP_BaseEntries(const double eq)
{
   if(eq<20) return 1;
   if(eq<30) return 2;
   if(eq<80) return 3;      // $30-$50 zone => up to 3
   if(eq<150) return 4;
   if(eq<300) return 6;
   if(eq<600) return 8;
   if(eq<1200) return 11;
   if(eq<2500) return 13;
   return BP_MAX_ENTRIES;   // R9
}
ENUM_BP_MODE BP_RiskMode(const AdaptiveSignal &sig, const double pnl)
{
   double eq=MathMax(1.0,AccountInfoDouble(ACCOUNT_EQUITY));
   double dd=(pnl<0?(-pnl/eq)*100.0:0.0);
   if(dd>=BP_DD_LOCK || g_lossStreak>=BP_LOSS_LOCK) return BP_LOCK;
   if(dd>=BP_DD_DEF || g_lossStreak>=BP_LOSS_DEF) return BP_DEF;
   int n=0; double wr=BP_WR(n);
   bool strong=(sig.valid && sig.bias!=BP_NONE && sig.strength>=0.55);
   if(strong && dd<BP_DD_DEF*0.35 && (n<3 || wr>=0.45)) return BP_AGG;
   if(strong && dd<BP_DD_DEF*0.50 && g_lossStreak==0) return BP_AGG;
   return BP_NORMAL;
}
int BP_Allowed(const ENUM_BP_MODE mode, const AdaptiveSignal &sig)
{
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   int a=BP_ClampI(BP_BaseEntries(eq),1,BP_MAX_ENTRIES);
   if(mode==BP_LOCK) return 0;
   if(mode==BP_DEF) return MathMax(1,a/2);
   if(sig.valid)
   {
      if(sig.strength<0.40) a=MathMax(1,a-1);
      if(sig.strength>=0.70 && mode==BP_AGG) a=MathMin(BP_MAX_ENTRIES,a+1);
   }
   // R8 reinforce
   if(eq>=30 && eq<80 && mode==BP_AGG) a=MathMax(a,2);
   return BP_ClampI(a,0,BP_MAX_ENTRIES);
}
double BP_Lot(const ENUM_ORDER_TYPE ty,const double px,const ENUM_BP_MODE mode)
{
   // R11 no martingale
   if(g_cycleLot>0 && BP_Count()>0) return BP_NormV(g_cycleLot);
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double lpl=BP_LossPerLot(BP_EmergSL());
   double lot=InpMinLot;
   if(lpl>0) lot=(eq*InpRiskPercent/100.0)/lpl;
   if(eq>=100) lot=MathMax(lot,InpMinLot*2);
   if(eq>=250) lot=MathMax(lot,InpMinLot*3);
   if(eq>=500) lot=MathMax(lot,InpMinLot*5);
   if(eq>=1000) lot=MathMax(lot,InpMinLot*8);
   if(eq>=2000) lot=MathMax(lot,InpMinLot*12);
   if(mode==BP_AGG) lot*=1.10;
   if(mode==BP_DEF) lot*=0.75;
   if(mode==BP_LOCK) lot=InpMinLot;
   lot=MathMin(lot,BP_MaxLot(ty,px));
   return BP_NormV(lot);
}

//======================================================================
// R10 SAME-PRICE BURST (one shot, one price)
//======================================================================
bool BP_OpenOne(const ENUM_BP_BIAS bias, const double lot, const double price)
{
   if(bias==BP_BUY && !InpAllowBuy) return false;
   if(bias==BP_SELL && !InpAllowSell) return false;
   if(!BP_TradeOk()) return false;
   ENUM_ORDER_TYPE_FILLING f; BP_Fill(f);
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFilling(f);
   double dist=MathMax(BP_EmergSL(), BP_Stops()+2*BP_Point());
   if(bias==BP_BUY) return trade.Buy(lot,g_symbol,price,BP_NormP(price-dist),0,"BP-BUY");
   return trade.Sell(lot,g_symbol,price,BP_NormP(price+dist),0,"BP-SELL");
}

// Architecture: Risk Manager decides count, all fills at SAME quoted price
bool BP_FireSamePriceBurst(const AdaptiveSignal &sig)
{
   string why;
   if(!BP_CanEntry(why)){ g_rule=why; BP_Log(g_rule); return false; }

   ENUM_BP_BIAS bias=g_bias; if(bias==BP_NONE) bias=sig.bias; if(bias==BP_NONE){ g_rule="no bias"; return false; }
   ENUM_BP_BIAS openB=BP_OpenBias();
   if(openB!=BP_NONE && openB!=bias){ g_rule="R10 one-way only"; return false; }

   g_mode=BP_RiskMode(sig,BP_FloatPnl());
   int allowed=BP_Allowed(g_mode,sig);
   int openN=BP_Count();
   if(g_mode==BP_LOCK){ g_rule="R7 LOCKDOWN"; return false; }
   if(allowed<=0){ g_rule="R7 zero allowed"; return false; }
   if(openN>=allowed){ g_rule="R7 at allowed"; return false; }
   if(openN>=BP_MAX_ENTRIES){ g_rule="R9 max 15"; return false; }
   if(g_mode==BP_DEF && openN>=1){ g_rule="R7 DEFENSIVE no-add"; return false; }

   // How many to open now at same price
   int want=allowed-openN;
   if(openN==0)
   {
      // first pulse: open RM count, capped sensibly (R8 => 2-3 on small equity when clean)
      want=allowed;
      if(want>3 && g_mode!=BP_AGG) want=MathMin(want,2);
      if(want>4) want=4;
   }
   else
   {
      // continuation add: only +1 if still same price and strength
      want=1;
   }

   ENUM_ORDER_TYPE ty=(bias==BP_BUY?ORDER_TYPE_BUY:ORDER_TYPE_SELL);
   double price=(bias==BP_BUY?SymbolInfoDouble(g_symbol,SYMBOL_ASK):SymbolInfoDouble(g_symbol,SYMBOL_BID));
   if(g_firstFill>0 && MathAbs(price-g_firstFill)>BP_SameBand())
   { g_rule="R10 skip: not same price"; BP_Log(g_rule); return false; }

   double lot=BP_Lot(ty,price,g_mode);
   if(lot<=0){ g_rule="lot=0"; return false; }

   int made=0;
   for(int i=0;i<want;i++)
   {
      // Re-check same price every order (slippage guard)
      double px=(bias==BP_BUY?SymbolInfoDouble(g_symbol,SYMBOL_ASK):SymbolInfoDouble(g_symbol,SYMBOL_BID));
      if(g_firstFill>0 && MathAbs(px-g_firstFill)>BP_SameBand()) break;
      if(g_firstFill<=0) g_firstFill=px; // lock band to first quote
      else
      {
         // force same-price intent: only accept if still inside band of first fill
         if(MathAbs(px-g_firstFill)>BP_SameBand()) break;
      }

      if(!BP_OpenOne(bias,lot,px))
      {
         BP_Log("R10 order fail ret="+IntegerToString(trade.ResultRetcode()));
         break;
      }
      if(g_cycleLot<=0) g_cycleLot=lot; // R11 lock lot
      made++;
      openN++;
      if(openN>=allowed || openN>=BP_MAX_ENTRIES) break;
   }

   if(made>0)
   {
      g_bias=bias;
      g_state=BP_MANAGE;
      g_rule="R10 burst x"+IntegerToString(made)+" @ "+DoubleToString(g_firstFill,BP_Digits())+
             " lot="+DoubleToString(g_cycleLot,2)+" mode="+BP_ModeName(g_mode);
      BP_Log(g_rule);
      return true;
   }
   return false;
}

//======================================================================
// R12 SMART EXIT
//======================================================================
bool BP_ThreatClose(const ENUM_BP_BIAS openB, const AdaptiveSignal &sig, const double pnl)
{
   if(openB==BP_NONE) return false;
   double ms=BP_MinSecure();
   if(pnl>g_peakPnl) g_peakPnl=pnl;
   bool opp=false;
   if(sig.valid)
   {
      if(openB==BP_BUY) opp=(sig.downBias>=0.58 && sig.netMove<0);
      else opp=(sig.upBias>=0.58 && sig.netMove>0);
   }
   bool cth=BP_CandleThreat(openB);
   bool had=(g_peakPnl>=ms);
   bool give=(had && pnl<=g_peakPnl*0.55);
   bool flip=(had && pnl<ms*0.35 && (opp||cth));
   if(had && opp && cth) return true;
   if(had && give && (opp||cth)) return true;
   if(flip) return true;
   if(g_mode==BP_LOCK && pnl<0 && opp) return true;
   return false;
}

//======================================================================
// R15 RULE MONITOR
//======================================================================
void BP_UpdateMonitor()
{
   string why; bool sess=BP_SessionOK(); bool news=BP_NewsBlocked(why);
   string newsTxt=news?why:"OK";
   string sessTxt=sess?"OK":"BLOCK R1";
   int openN=BP_Count();
   int allow=BP_Allowed(g_mode,g_lastSig);
   double eq=AccountInfoDouble(ACCOUNT_EQUITY);
   string txt=
      "BalochPulse ARCH v2.50\n"+
      "Symbol: "+g_symbol+(g_gold?" (XAU)":" (US30)")+"\n"+
      "R1 Session: "+sessTxt+"\n"+
      "R2/R3 News: "+newsTxt+"\n"+
      "State: "+BP_StateName(g_state)+" | Mode: "+BP_ModeName(g_mode)+"\n"+
      "Bias: "+(g_bias==BP_BUY?"BUY":(g_bias==BP_SELL?"SELL":"NONE"))+"\n"+
      "Signal: up="+DoubleToString(g_lastSig.upBias,2)+
      " dn="+DoubleToString(g_lastSig.downBias,2)+
      " win="+IntegerToString(g_lastSig.windowSec)+"s"+
      " str="+DoubleToString(g_lastSig.strength,2)+"\n"+
      "R7/R8/R9 Entries: "+IntegerToString(openN)+"/"+IntegerToString(allow)+" (max 15) eq="+DoubleToString(eq,2)+"\n"+
      "R10/R11 Fill: "+(g_firstFill>0?DoubleToString(g_firstFill,BP_Digits()):"-")+
      " lot="+(g_cycleLot>0?DoubleToString(g_cycleLot,2):"-")+"\n"+
      "RuleNow: "+g_rule;
   Comment(txt);
}

//======================================================================
// STATE MACHINE R6
//======================================================================
void BP_ResetSetup(const bool clearBasket)
{
   g_bias=BP_NONE; g_setupTime=0; g_impStart=0; g_impExtreme=0; g_impMove=0; g_pbExtreme=0; g_pbSeen=false;
   if(clearBasket && BP_Count()==0){ g_firstFill=0; g_cycleLot=0; g_peakPnl=0; }
}
void BP_Cooldown(const string why)
{
   g_rule="cooldown: "+why; BP_Log(g_rule);
   BP_ResetSetup(true); g_state=BP_COOLDOWN; g_cooldownUntil=TimeCurrent()+BP_COOLDOWN;
}

void BP_Manage()
{
   if(BP_Count()<=0){ BP_Cooldown("flat"); return; }
   BP_EnsureSL();
   AdaptiveSignal sig=BP_Signal(); g_lastSig=sig;
   ENUM_BP_BIAS openB=BP_OpenBias(); if(openB!=BP_NONE) g_bias=openB;
   double pnl=BP_FloatPnl(); g_mode=BP_RiskMode(sig,pnl);

   string why;
   bool news=BP_NewsBlocked(why);
   if(BP_ThreatClose(openB,sig,pnl))
   {
      if(BP_CloseAll("R12 threat-close pnl="+DoubleToString(pnl,2)))
      { BP_MemAdd(pnl); BP_Cooldown("R12"); }
      return;
   }
   if(news && pnl>=BP_MinSecure() && (BP_CandleThreat(openB) ||
      (sig.valid && openB==BP_BUY && sig.downBias>0.55) ||
      (sig.valid && openB==BP_SELL && sig.upBias>0.55)))
   {
      if(BP_CloseAll("R3/R12 news-protect "+why)){ BP_MemAdd(pnl); BP_Cooldown("news-protect"); }
      return;
   }

   // Adds only if still strength + same price + RM allows
   if(g_mode==BP_LOCK || g_mode==BP_DEF){ g_rule="R7 no-add mode "+BP_ModeName(g_mode); return; }
   if(!BP_CanEntry(why)){ g_rule=why; return; }
   if(sig.valid && sig.bias==openB && BP_CandleOK(openB) && sig.strength>=0.45)
   {
      g_state=BP_BURST;
      BP_FireSamePriceBurst(sig);
   }
   else g_rule="R7 waiting clean continuation";
}

void BP_Process(const AdaptiveSignal &sig)
{
   if(g_setupTime>0 && TimeCurrent()-g_setupTime>BP_SETUP_EXPIRE)
   { g_rule="setup expired"; BP_ResetSetup(false); g_state=BP_IDLE; return; }
   if(!sig.valid){ g_rule="R4 waiting adaptive ticks"; return; }

   // detect impulse
   if(g_state==BP_IDLE || g_state==BP_BIAS_DETECT)
   {
      if(sig.bias!=BP_NONE && BP_CandleOK(sig.bias) && sig.strength>=0.35)
      {
         g_bias=sig.bias; g_setupTime=TimeCurrent();
         g_impStart=BP_Mid(); g_impExtreme=g_impStart; g_impMove=MathAbs(sig.netMove);
         g_pbSeen=false; g_pbExtreme=g_impStart; g_state=BP_IMPULSE;
         g_rule="R6 impulse "+(g_bias==BP_BUY?"BUY":"SELL");
         BP_Log(g_rule+" str="+DoubleToString(sig.strength,2)+" win="+IntegerToString(sig.windowSec));
      }
      else { g_state=BP_BIAS_DETECT; g_rule="R4/R5 scanning bias"; }
      return;
   }

   if(g_state==BP_IMPULSE)
   {
      if(sig.bias!=BP_NONE && sig.bias!=g_bias){ g_rule="R6 bias flip cancel"; BP_ResetSetup(false); g_state=BP_IDLE; return; }
      double mid=BP_Mid();
      if(g_bias==BP_BUY && mid>g_impExtreme) g_impExtreme=mid;
      if(g_bias==BP_SELL && (g_impExtreme<=0 || mid<g_impExtreme)) g_impExtreme=mid;
      g_impMove=MathMax(g_impMove, MathAbs(mid-g_impStart));
      // impulse established by absolute unit move (not fragile ratio only)
      if(g_impMove>=BP_Unit()*0.20)
      {
         g_state=BP_PULLBACK; g_pbExtreme=mid; g_rule="R6 wait pullback";
      }
      else g_rule="R6 building impulse";
      return;
   }

   if(g_state==BP_PULLBACK)
   {
      double mid=BP_Mid();
      double unit=BP_Unit();
      if(g_bias==BP_BUY)
      {
         if(mid>g_impExtreme) g_impExtreme=mid;
         if(!g_pbSeen || mid<g_pbExtreme) g_pbExtreme=mid;
         double pb=g_impExtreme-mid;
         if(pb>=unit*1.25){ g_rule="R6 pullback too deep"; BP_ResetSetup(false); g_state=BP_IDLE; return; }
         if(pb>=unit*0.12) g_pbSeen=true;
         if(g_pbSeen && sig.bias==BP_BUY && mid>g_pbExtreme+unit*0.04 && BP_CandleOK(BP_BUY))
         { g_state=BP_BURST; g_rule="R6 pullback done -> BURST"; }
         else g_rule=g_pbSeen?"R6 waiting resume":"R6 waiting pullback";
      }
      else if(g_bias==BP_SELL)
      {
         if(mid<g_impExtreme) g_impExtreme=mid;
         if(!g_pbSeen || mid>g_pbExtreme) g_pbExtreme=mid;
         double pb=mid-g_impExtreme;
         if(pb>=unit*1.25){ g_rule="R6 pullback too deep"; BP_ResetSetup(false); g_state=BP_IDLE; return; }
         if(pb>=unit*0.12) g_pbSeen=true;
         if(g_pbSeen && sig.bias==BP_SELL && mid<g_pbExtreme-unit*0.04 && BP_CandleOK(BP_SELL))
         { g_state=BP_BURST; g_rule="R6 pullback done -> BURST"; }
         else g_rule=g_pbSeen?"R6 waiting resume":"R6 waiting pullback";
      }
      return;
   }

   if(g_state==BP_BURST)
   {
      if(sig.bias!=BP_NONE && sig.bias!=g_bias)
      {
         if(BP_Count()>0) g_state=BP_MANAGE;
         else { BP_ResetSetup(false); g_state=BP_IDLE; }
         g_rule="R6 bias lost in burst";
         return;
      }
      BP_FireSamePriceBurst(sig);
      if(BP_Count()>0) g_state=BP_MANAGE;
   }
}

void BP_OnTickState()
{
   BP_PushTick(); // R15 always-on tick engine

   if(BP_Count()>0){ g_state=BP_MANAGE; BP_Manage(); BP_UpdateMonitor(); return; }

   if(g_state==BP_COOLDOWN)
   {
      if(TimeCurrent()>=g_cooldownUntil){ g_state=BP_IDLE; BP_ResetSetup(true); g_rule="ready"; }
      else g_rule="cooldown";
      BP_UpdateMonitor(); return;
   }

   string why;
   if(!BP_CanEntry(why))
   {
      if(g_state!=BP_IDLE && g_state!=BP_COOLDOWN){ BP_ResetSetup(false); g_state=BP_IDLE; }
      g_rule=why;
      // engines still active: keep updating signal for monitor
      g_lastSig=BP_Signal();
      BP_UpdateMonitor();
      return;
   }

   AdaptiveSignal sig=BP_Signal(); g_lastSig=sig;
   g_mode=BP_RiskMode(sig,0);
   if(g_mode==BP_LOCK){ BP_ResetSetup(false); g_state=BP_IDLE; g_rule="R7 LOCKDOWN"; BP_UpdateMonitor(); return; }

   BP_Process(sig);
   BP_UpdateMonitor();
}

//======================================================================
void BP_TrackDeal(const ulong deal)
{
   if(!HistoryDealSelect(deal)) return;
   if(HistoryDealGetString(deal,DEAL_SYMBOL)!=g_symbol) return;
   if((long)HistoryDealGetInteger(deal,DEAL_MAGIC)!=InpMagic) return;
   long e=HistoryDealGetInteger(deal,DEAL_ENTRY);
   if(e!=DEAL_ENTRY_OUT && e!=DEAL_ENTRY_OUT_BY) return;
   double pnl=HistoryDealGetDouble(deal,DEAL_PROFIT)+HistoryDealGetDouble(deal,DEAL_SWAP)+HistoryDealGetDouble(deal,DEAL_COMMISSION);
   BP_MemAdd(pnl);
}

int OnInit()
{
   if(!BP_Validate()) return INIT_FAILED;
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   ENUM_ORDER_TYPE_FILLING f; BP_Fill(f); trade.SetTypeFilling(f);
   BP_TickInit(); BP_MemInit(); BP_ResetSetup(true);
   g_state=BP_IDLE; g_mode=BP_NORMAL; g_rule="ARCH v2.50 locked";
   BP_Log("ARCH v2.50 | R1 session | R2/R3 news | R4 adaptive tick | R5 candle | R6 pullback | R7 RM | R8 2-3@$30-50 | R9 max15 | R10 same-price | R11 no-martingale | R12 smart-exit | R14 XAU/US30");
   BP_UpdateMonitor();
   return INIT_SUCCEEDED;
}
void OnDeinit(const int r){ Comment(""); BP_Log("deinit "+IntegerToString(r)); }
void OnTick(){ if(!g_ok) return; BP_OnTickState(); }
void OnTradeTransaction(const MqlTradeTransaction &tr,const MqlTradeRequest &rq,const MqlTradeResult &rs)
{
   if(tr.type!=TRADE_TRANSACTION_DEAL_ADD || tr.deal==0) return;
   if(!HistoryDealSelect(tr.deal))
   {
      HistorySelect(TimeCurrent()-86400,TimeCurrent()+60);
      if(!HistoryDealSelect(tr.deal)) return;
   }
   BP_TrackDeal(tr.deal);
}
//+------------------------------------------------------------------+
