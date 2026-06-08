//+------------------------------------------------------------------+
//|                                            MA_Cross_ATR_EA.mq5    |
//|   EMA-crossover Expert Advisor with an ATR-based stop loss and    |
//|   RISK-BASED position sizing (size each trade to lose a fixed %   |
//|   of the account if the stop is hit). Includes a daily-loss guard |
//|   so the EA stops trading after a set drawdown each day.          |
//|                                                                   |
//|   Study this, then TEST it in the Strategy Tester before using it |
//|   on any real or client account. A backtest that looks good is    |
//|   not the same as a robust strategy.                              |
//+------------------------------------------------------------------+
#property copyright "Finance-broski"
#property version   "1.00"
#property description "EMA crossover entries, ATR stop, risk-% sizing, daily-loss guard."

#include <Trade/Trade.mqh>     // gives us the CTrade helper for sending orders
CTrade trade;

//--- INPUTS: the knobs a client can tune from the EA settings -------
input int    FastMA       = 20;      // fast EMA period
input int    SlowMA       = 50;      // slow EMA period
input int    ATRPeriod    = 14;      // ATR period (measures volatility for the stop)
input double ATRmultSL    = 2.0;     // stop distance = ATRmultSL * ATR
input double RewardRisk    = 1.5;    // take-profit = RewardRisk * stop distance (0 = no TP)
input double RiskPercent  = 0.5;     // % of balance risked per trade (0.25-0.5 is sane)
input double DailyLossPct = 3.0;     // stop trading for the day after this % equity loss
input ulong  MagicNumber  = 990011;  // tags THIS EA's trades so it ignores others
input int    SlippagePts  = 20;      // max price deviation allowed (points)
input bool   DebugLog     = false;   // set true to log every signal/order to the Journal (debugging)

//--- GLOBALS -------------------------------------------------------
int      hFast, hSlow, hATR;         // indicator handles (created once)
datetime lastBarTime  = 0;           // for "act once per bar" logic
double   dayStartEquity = 0;         // equity recorded at the start of the day
int      dayStamp     = -1;          // which day-of-year dayStartEquity belongs to

//+------------------------------------------------------------------+
//| OnInit: runs ONCE when the EA starts. Set things up here.        |
//+------------------------------------------------------------------+
int OnInit()
{
   // Create indicator handles once and reuse them — cheaper than rebuilding each tick.
   hFast = iMA(_Symbol, _Period, FastMA, 0, MODE_EMA, PRICE_CLOSE);
   hSlow = iMA(_Symbol, _Period, SlowMA, 0, MODE_EMA, PRICE_CLOSE);
   hATR  = iATR(_Symbol, _Period, ATRPeriod);

   if(hFast == INVALID_HANDLE || hSlow == INVALID_HANDLE || hATR == INVALID_HANDLE)
   {
      Print("ERROR: could not create indicator handles");
      return(INIT_FAILED);
   }

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePts);
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| OnDeinit: runs ONCE when the EA stops. Clean up here.            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   IndicatorRelease(hFast);
   IndicatorRelease(hSlow);
   IndicatorRelease(hATR);
}

//+------------------------------------------------------------------+
//| OnTick: runs on EVERY price change. The heart of the EA.         |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1) Only act once per COMPLETED bar (not on every tick) — avoids over-trading.
   if(!IsNewBar()) return;

   // 2) Reset the daily-loss tracker when a new day begins.
   UpdateDayTracker();

   // 3) If today's loss limit is already hit, stop opening new trades today.
   if(DailyLossHit()) return;

   // 4) Read the last two CLOSED bars of each indicator (index 0 = newer, 1 = older).
   double fast[], slow[], atr[];
   ArraySetAsSeries(fast, true);
   ArraySetAsSeries(slow, true);
   ArraySetAsSeries(atr,  true);
   if(CopyBuffer(hFast, 0, 1, 2, fast) < 2) return;
   if(CopyBuffer(hSlow, 0, 1, 2, slow) < 2) return;
   if(CopyBuffer(hATR,  0, 1, 1, atr)  < 1) return;

   // 5) Detect the crossover on the just-closed bar.
   bool crossUp   = (fast[1] <= slow[1] && fast[0] > slow[0]); // fast crossed ABOVE slow -> buy
   bool crossDown = (fast[1] >= slow[1] && fast[0] < slow[0]); // fast crossed BELOW slow -> sell

   bool haveLong  = PositionExists(POSITION_TYPE_BUY);
   bool haveShort = PositionExists(POSITION_TYPE_SELL);

   if(DebugLog && (crossUp || crossDown))
      PrintFormat("signal cross%s  fast0=%.5f slow0=%.5f  atr=%.5f  haveL=%d haveS=%d",
                  crossUp ? "UP" : "DOWN", fast[0], slow[0], atr[0], haveLong, haveShort);

   // 6) Act: flip on opposite signal, otherwise open in the signal's direction.
   if(crossUp)
   {
      if(haveShort) ClosePositions();
      if(!haveLong) OpenTrade(ORDER_TYPE_BUY, atr[0]);
   }
   else if(crossDown)
   {
      if(haveLong) ClosePositions();
      if(!haveShort) OpenTrade(ORDER_TYPE_SELL, atr[0]);
   }
}

//+------------------------------------------------------------------+
//| Returns true the first tick of each new bar.                     |
//+------------------------------------------------------------------+
bool IsNewBar()
{
   datetime t = iTime(_Symbol, _Period, 0);
   if(t != lastBarTime) { lastBarTime = t; return true; }
   return false;
}

//+------------------------------------------------------------------+
//| Records equity at the start of each new day.                     |
//+------------------------------------------------------------------+
void UpdateDayTracker()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.day_of_year != dayStamp)
   {
      dayStamp       = dt.day_of_year;
      dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   }
}

//+------------------------------------------------------------------+
//| True once today's equity drop exceeds DailyLossPct.              |
//+------------------------------------------------------------------+
bool DailyLossHit()
{
   if(dayStartEquity <= 0) return false;
   double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct = (dayStartEquity - eq) / dayStartEquity * 100.0;
   return (ddPct >= DailyLossPct);
}

//+------------------------------------------------------------------+
//| Is there an open position of this type, by THIS EA, on this sym? |
//+------------------------------------------------------------------+
bool PositionExists(ENUM_POSITION_TYPE type)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);   // selects the position and returns its ticket
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol
         && PositionGetInteger(POSITION_MAGIC) == (long)MagicNumber
         && (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == type)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Close all positions opened by THIS EA on this symbol.            |
//+------------------------------------------------------------------+
void ClosePositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) == _Symbol
         && PositionGetInteger(POSITION_MAGIC) == (long)MagicNumber)
         trade.PositionClose(ticket);
   }
}

//+------------------------------------------------------------------+
//| Open a trade with an ATR stop, optional TP, and risk-% sizing.   |
//+------------------------------------------------------------------+
void OpenTrade(ENUM_ORDER_TYPE type, double atrValue)
{
   double stopDist = atrValue * ATRmultSL;     // stop distance in PRICE terms
   if(stopDist <= 0) return;

   double price = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(_Symbol, SYMBOL_ASK)
                                           : SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double sl = (type == ORDER_TYPE_BUY) ? price - stopDist : price + stopDist;
   double tp = 0.0;
   if(RewardRisk > 0)
      tp = (type == ORDER_TYPE_BUY) ? price + stopDist * RewardRisk
                                    : price - stopDist * RewardRisk;

   // normalize to the symbol's price precision
   price = NormalizeDouble(price, _Digits);
   sl    = NormalizeDouble(sl,    _Digits);
   tp    = NormalizeDouble(tp,    _Digits);

   double lots = CalcLots(stopDist);
   if(lots <= 0)
   {
      if(DebugLog) PrintFormat("OpenTrade skipped: lots<=0  (stopDist=%.5f)", stopDist);
      return;
   }

   bool ok;
   if(type == ORDER_TYPE_BUY) ok = trade.Buy(lots, _Symbol, price, sl, tp, "MA cross long");
   else                       ok = trade.Sell(lots, _Symbol, price, sl, tp, "MA cross short");

   if(DebugLog)
   {
      if(ok) PrintFormat("ORDER OK  %s lots=%.2f price=%.5f sl=%.5f tp=%.5f",
                         (type == ORDER_TYPE_BUY) ? "BUY" : "SELL", lots, price, sl, tp);
      else   PrintFormat("ORDER FAIL  retcode=%d  %s",
                         trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| RISK-BASED SIZING: lots such that hitting the stop loses exactly |
//| RiskPercent of the balance. This is what separates a pro EA from |
//| a "fixed 0.1 lot" toy that blows accounts.                       |
//+------------------------------------------------------------------+
double CalcLots(double stopDist)
{
   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * RiskPercent / 100.0;
   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE); // $ per tick per 1.0 lot
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

   // FALLBACK: the tester's "profit in pips" mode (and some brokers) report tick
   // value/size as 0, which would zero the lot size and silently skip every trade.
   // Rebuild them from point + contract size so risk sizing still works.
   if(tickSize <= 0)  tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(tickValue <= 0)
   {
      double contract = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
      if(contract > 0 && tickSize > 0) tickValue = tickSize * contract;
   }
   if(tickValue <= 0 || tickSize <= 0)
   {
      if(DebugLog) PrintFormat("CalcLots: no tick value/size -> can't size (tv=%.5f ts=%.5f)", tickValue, tickSize);
      return 0;
   }

   double lossPerLot = (stopDist / tickSize) * tickValue;   // $ lost per 1.0 lot if stopped
   if(lossPerLot <= 0) return 0;

   double lots = riskMoney / lossPerLot;

   // clamp to the broker's min / max / step volume rules
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) step = (minLot > 0 ? minLot : 0.01);
   lots = MathFloor(lots / step) * step;
   lots = MathMax(minLot, MathMin(maxLot, lots));
   return lots;
}
//+------------------------------------------------------------------+