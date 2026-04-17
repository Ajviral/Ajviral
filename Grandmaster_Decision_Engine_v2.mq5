//+------------------------------------------------------------------+
//| GRANDMASTER UNIFIED DECISION ENGINE v2.0                        |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property indicator_plots 0

//================ INPUTS =================//
input int    Timer_Seconds = 5;
input int    ATR_Period    = 14;
input int    Quality_Bars  = 20;   // M1 bars for market quality assessment

input string NAS100 = "NAS100";
input string US30   = "US30";
input string GOLD   = "XAUUSD";
input string DXY    = "USDX";

//================ ENUMS =================//
enum MARKET_PHASE    { ACCUMULATION, MANIPULATION, EXPANSION, UNKNOWN };
enum MARKET_QUALITY  { CLEAN, MIXED, CHOP };
enum TRADE_DIRECTION { DIR_LONG, DIR_SHORT, DIR_NONE };

//================ STATE =================//
struct MasterState
{
   MARKET_PHASE     phase;
   MARKET_QUALITY   quality;
   TRADE_DIRECTION  direction;

   bool   no_trade_now;       // per-minute snapshot; renamed from no_trade_day
   int    no_trade_score;

   bool   sweep_detected;     // session-persistent: set true, only reset at session open
   bool   sweep_pdh;          // session-persistent: PDH swept bearishly this session
   bool   sweep_pdl;          // session-persistent: PDL swept bullishly this session
   bool   displacement_valid;
   bool   mitigation_valid;

   int    smt_score;          // session-persistent: only upgrades intra-session
   bool   smt_confirmed;

   int    fat_tail_score;
   bool   fat_tail_active;

   int    total_score;
   int    press_score;

   double risk_multiplier;
   string decision;
};

MasterState state;

//================ GLOBALS =================//
int      ATR_Handle;
double   ATR_Buffer[];
double   ATR_Value;

double   PDH, PDL;
datetime last_bar_time;
int      last_ny_day = -1;   // tracks NY calendar day for daily session reset

//+------------------------------------------------------------------+
int OnInit()
{
   ATR_Handle = iATR(_Symbol, PERIOD_M5, ATR_Period);
   if(ATR_Handle == INVALID_HANDLE)
   {
      Print("FATAL: iATR handle creation failed for ", _Symbol, " M5. Indicator cannot run.");
      return INIT_FAILED;
   }
   ArraySetAsSeries(ATR_Buffer, true);
   EventSetTimer(Timer_Seconds);
   return INIT_SUCCEEDED;
}
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   Comment("");
}
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total, const int prev_calculated,
                const datetime &time[], const double &open[],
                const double &high[], const double &low[],
                const double &close[], const long &tick_volume[],
                const long &volume[], const int &spread[])
{
   return rates_total;
}
//+------------------------------------------------------------------+
void OnTimer()
{
   if(!IsNewMinute()) return;

   datetime ny = GetNYTime();

   UpdateATR();
   CheckSessionReset(ny);
   UpdateMarketPhase(ny);
   UpdateMarketQuality();
   UpdateDailyLevels();

   DetectSweep();
   DetectDisplacement();
   DetectMitigation();

   UpdateSMT();
   UpdateFatTailState(ny);
   UpdateNoTradeState(ny);

   CalculateScore(ny);
   CalculatePressScore();

   FinalDecision();

   RenderDashboard(ny);
   ChartRedraw();
}

//+------------------------------------------------------------------+
//| UTIL                                                             |
//+------------------------------------------------------------------+
bool IsNewMinute()
{
   datetime t = iTime(_Symbol, PERIOD_M1, 0);
   if(t == last_bar_time) return false;
   last_bar_time = t;
   return true;
}

// FIX #1: Proper DST-aware NY time. Hardcoded -4 was wrong Nov-Mar (EST = -5).
// Spring forward: 2nd Sunday of March at 07:00 UTC.
// Fall back:      1st Sunday of November at 06:00 UTC.
// Day numbers are zero-padded so StringToTime parses reliably on all platforms.
datetime GetNYTime()
{
   datetime gmt = TimeGMT();
   MqlDateTime g;
   TimeToStruct(gmt, g);
   int y = g.year;

   MqlDateTime m;
   TimeToStruct(StringToTime(IntegerToString(y) + ".03.01 00:00"), m);
   int sd = (m.day_of_week == 0) ? 8 : 15 - m.day_of_week;
   string sds = (sd < 10 ? "0" : "") + IntegerToString(sd);
   datetime spring = StringToTime(IntegerToString(y) + ".03." + sds + " 07:00");

   MqlDateTime n;
   TimeToStruct(StringToTime(IntegerToString(y) + ".11.01 00:00"), n);
   int fd = (n.day_of_week == 0) ? 1 : 8 - n.day_of_week;
   string fds = (fd < 10 ? "0" : "") + IntegerToString(fd);
   datetime fall = StringToTime(IntegerToString(y) + ".11." + fds + " 06:00");

   int offset = (gmt >= spring && gmt < fall) ? -4 : -5;
   return gmt + offset * 3600;
}

// FIX #2: Session reset at NY midnight. Clears all session-persistent state so
// sweep, SMT, and direction flags do not carry across trading days.
void CheckSessionReset(datetime ny)
{
   MqlDateTime t;
   TimeToStruct(ny, t);
   if(t.day == last_ny_day) return;
   last_ny_day = t.day;

   state.sweep_detected = false;
   state.sweep_pdh      = false;
   state.sweep_pdl      = false;
   state.smt_score      = 0;
   state.smt_confirmed  = false;
   state.direction      = DIR_NONE;
}

//+------------------------------------------------------------------+
//| ATR                                                              |
//+------------------------------------------------------------------+
void UpdateATR()
{
   if(CopyBuffer(ATR_Handle, 0, 0, 1, ATR_Buffer) <= 0) return;
   ATR_Value = ATR_Buffer[0];
}

//+------------------------------------------------------------------+
//| MARKET PHASE & QUALITY                                           |
//+------------------------------------------------------------------+

// FIX #7: ICT-aligned session boundaries (all times NY).
// Previous code labelled 7-9 AM "manipulation" and started expansion at 9 AM;
// the actual NY cash open is 9:30. The 5-7 AM gap between London and NY
// pre-market is now classified as ACCUMULATION (dead consolidation window).
void UpdateMarketPhase(datetime ny)
{
   MqlDateTime t;
   TimeToStruct(ny, t);
   int h = t.hour, m = t.min;

   bool asian   = (h >= 20) || (h < 2);                              // 8 PM – 2 AM
   bool gap     = (h >= 5 && h < 7);                                 // 5 AM – 7 AM (between sessions)
   bool london  = (h >= 2 && h < 5);                                 // 2 AM – 5 AM
   bool ny_pre  = (h >= 7) && !(h > 9 || (h == 9 && m >= 30));      // 7 AM – 9:29 AM
   bool ny_am   = ((h == 9 && m >= 30) || h == 10 || (h == 11 && m <= 30)); // 9:30 AM – 11:30 AM

   if(asian || gap)         state.phase = ACCUMULATION;
   else if(london || ny_pre) state.phase = MANIPULATION;
   else if(ny_am)            state.phase = EXPANSION;
   else                      state.phase = UNKNOWN;
}

// FIX #8: Lookback extended from 5 to Quality_Bars (default 20).
// 5 M1 bars = 5 minutes; a single news spike produced false CHOP readings.
// 20 bars gives a stable 20-minute quality picture across the kill zone.
void UpdateMarketQuality()
{
   int overlap = 0;
   for(int i = 1; i <= Quality_Bars; i++)
   {
      double h  = iHigh(_Symbol, PERIOD_M1, i);
      double l  = iLow(_Symbol, PERIOD_M1, i);
      double ph = iHigh(_Symbol, PERIOD_M1, i + 1);
      double pl = iLow(_Symbol, PERIOD_M1, i + 1);
      if(l < ph && h > pl) overlap++;
   }
   double ratio = (double)overlap / Quality_Bars;
   if(ratio < 0.3)      state.quality = CLEAN;
   else if(ratio < 0.7) state.quality = MIXED;
   else                 state.quality = CHOP;
}

//+------------------------------------------------------------------+
//| STRUCTURE                                                        |
//+------------------------------------------------------------------+
void UpdateDailyLevels()
{
   PDH = iHigh(_Symbol, PERIOD_D1, 1);
   PDL = iLow(_Symbol, PERIOD_D1, 1);
}

// FIX #3a: Sweep flags are now session-persistent (set true, never cleared mid-session).
// Previously reset to false every minute, causing the decision engine to see
// "WAIT SWEEP" even after a confirmed sweep had already occurred.
// FIX #3b: Direction is derived from sweep context and stored in state.
// FIX #3c: Uses last completed M1 bar (index 1) — not the forming candle (index 0).
void DetectSweep()
{
   double high  = iHigh(_Symbol, PERIOD_M1, 1);
   double low   = iLow(_Symbol, PERIOD_M1, 1);
   double close = iClose(_Symbol, PERIOD_M1, 1);

   // Bearish sweep: wick above PDH, closed back below — liquidity taken, short bias
   if(high > PDH && close < PDH)
   {
      state.sweep_pdh      = true;
      state.sweep_detected = true;
   }

   // Bullish sweep: wick below PDL, closed back above — liquidity taken, long bias
   if(low < PDL && close > PDL)
   {
      state.sweep_pdl      = true;
      state.sweep_detected = true;
   }

   // Direction: first sweep establishes session bias; conflicting sweeps defer to first
   if(state.sweep_pdl && !state.sweep_pdh)      state.direction = DIR_LONG;
   else if(state.sweep_pdh && !state.sweep_pdl) state.direction = DIR_SHORT;
}

// FIX #4: Now uses last completed M5 bar (index 1) compared against M5 ATR —
// previously used a forming M1 bar against an M5 ATR, creating a unit mismatch
// that made displacement nearly impossible to detect in normal conditions.
// Added body-to-range ratio (> 0.6) to require a full-bodied candle, not a spike.
void DetectDisplacement()
{
   if(ATR_Value <= 0) { state.displacement_valid = false; return; }

   double body  = MathAbs(iClose(_Symbol, PERIOD_M5, 1) - iOpen(_Symbol, PERIOD_M5, 1));
   double range = iHigh(_Symbol, PERIOD_M5, 1) - iLow(_Symbol, PERIOD_M5, 1);

   state.displacement_valid = (range > 0 && body > ATR_Value * 0.5 && body / range > 0.6);
}

// FIX #5: Replaced the permanent `true` placeholder with real mitigation logic.
// Mitigation = price returning to test the swept level (PDH or PDL) within a
// 15% ATR tolerance after a confirmed session sweep. No sweep → no mitigation.
void DetectMitigation()
{
   if(!state.sweep_detected || ATR_Value <= 0)
   {
      state.mitigation_valid = false;
      return;
   }

   double bid       = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double tolerance = ATR_Value * 0.15;

   if(state.sweep_pdl && MathAbs(bid - PDL) <= tolerance) { state.mitigation_valid = true;  return; }
   if(state.sweep_pdh && MathAbs(bid - PDH) <= tolerance) { state.mitigation_valid = true;  return; }

   state.mitigation_valid = false;
}

//+------------------------------------------------------------------+
//| SMT                                                              |
//+------------------------------------------------------------------+

// FIX #6: SMT score is now session-persistent (upgrade-only).
// Previously reset to 0 every minute; a divergence that fired at 9:31 would be
// gone by 9:32 even though the structural signal remains valid all session.
// Score only rises intra-session; CheckSessionReset() clears it at day boundary.
// Uses completed M5 bars (index 1) for consistency with displacement detection.
void UpdateSMT()
{
   string target  = "";
   bool   inverse = false;

   if(_Symbol == NAS100)    target = US30;
   else if(_Symbol == US30) target = NAS100;
   else if(_Symbol == GOLD) { target = DXY; inverse = true; }

   if(target == "") return;
   if(!SymbolSelect(target, true)) return;

   double t_pdl = iLow(target, PERIOD_D1, 1);
   double t_pdh = iHigh(target, PERIOD_D1, 1);

   double t_bar_low  = iLow(target, PERIOD_M5, 1);
   double t_bar_high = iHigh(target, PERIOD_M5, 1);
   double my_bar_low = iLow(_Symbol, PERIOD_M5, 1);

   int new_score = 0;

   if(inverse)
   {
      // DXY sweeps its PDH while Gold holds above its own PDL → bullish Gold
      if(t_bar_high > t_pdh && my_bar_low > PDL) new_score = 15;
   }
   else
   {
      // Correlated pair (NAS/DOW): target sweeps PDL while current symbol accumulates
      if(t_bar_low < t_pdl && my_bar_low > PDL) new_score = 15;
   }

   if(new_score > state.smt_score)
   {
      state.smt_score     = new_score;
      state.smt_confirmed = (state.smt_score >= 10);
   }
}

//+------------------------------------------------------------------+
//| FAT TAIL                                                         |
//+------------------------------------------------------------------+

// FIX #14b: Kill zone aligned to 9:30-9:45 (was 9:00-9:40).
// Current forming M5 bar (index 0) intentional here — fat tail is a
// real-time momentum observation, not a completed-bar confirmation.
void UpdateFatTailState(datetime ny)
{
   int score = 0;

   double range = iHigh(_Symbol, PERIOD_M5, 0) - iLow(_Symbol, PERIOD_M5, 0);
   if(range > ATR_Value)        score += 10;
   if(state.displacement_valid) score += 10;
   if(state.quality == CLEAN)   score += 5;

   MqlDateTime t;
   TimeToStruct(ny, t);
   if(t.hour == 9 && t.min >= 30 && t.min <= 45) score += 5;

   state.fat_tail_score  = score;
   state.fat_tail_active = (score >= 20);
}

//+------------------------------------------------------------------+
//| NO TRADE                                                         |
//+------------------------------------------------------------------+

// FIX #13: Renamed no_trade_day → no_trade_now. The flag re-evaluates every
// minute from live conditions; it was never a "day" flag in the first place.
void UpdateNoTradeState(datetime ny)
{
   int score = 0;

   double range = iHigh(_Symbol, PERIOD_M5, 0) - iLow(_Symbol, PERIOD_M5, 0);
   if(range < ATR_Value * 0.5)   score += 25;
   if(state.quality == CHOP)     score += 20;
   if(!state.displacement_valid) score += 15;
   if(!state.sweep_detected)     score += 15;
   if(!state.smt_confirmed)      score += 10;

   MqlDateTime t;
   TimeToStruct(ny, t);
   bool in_kill_zone = (t.hour == 9 && t.min >= 30 && t.min <= 45);
   if(!in_kill_zone) score += 15;

   state.no_trade_score = score;
   state.no_trade_now   = (score >= 60);
}

//+------------------------------------------------------------------+
//| SCORING                                                          |
//+------------------------------------------------------------------+
void CalculateScore(datetime ny)
{
   int total = 0;

   if(state.sweep_detected)     total += 20;
   if(state.displacement_valid) total += 20;
   if(state.quality == CLEAN)   total += 10;

   MqlDateTime t;
   TimeToStruct(ny, t);
   if(t.hour == 9 && t.min >= 30 && t.min <= 45) total += 10;

   if(state.mitigation_valid) total += 10;

   total += state.smt_score;
   total += state.fat_tail_score / 3;  // intentional integer division; caps contribution at 10

   state.total_score = total;
}

// FIX #9: Replaced int arithmetic with double throughout to eliminate systematic
// truncation (e.g., 85 * 0.3 = 25.5 was flooring to 25, silently affecting
// borderline 79→80 and 64→65 threshold decisions).
// Fat Tail and SMT are explicitly double-weighted relative to base conditions:
// they are the primary institutional press signals and deserve extra emphasis
// beyond their already-included share of total_score.
void CalculatePressScore()
{
   double score = 0.0;
   score += (double)state.total_score   * 0.3;   // base conditions: 30% contribution
   score += (double)state.fat_tail_score;          // full extra weight: primary press driver
   score += (double)state.smt_score;               // full extra weight: institutional confirmation
   if(state.quality == CLEAN) score += 10.0;
   if(state.no_trade_now)     score -= 20.0;

   state.press_score = (int)MathRound(score);

   if(state.press_score >= 80)      state.risk_multiplier = 2.0;
   else if(state.press_score >= 65) state.risk_multiplier = 1.5;
   else if(state.press_score >= 50) state.risk_multiplier = 1.0;
   else                             state.risk_multiplier = 0.5;
}

//+------------------------------------------------------------------+
//| FINAL DECISION                                                   |
//+------------------------------------------------------------------+

// FIX #10: TRADE_DIRECTION enum propagated into decision string ([LONG]/[SHORT]).
// FIX #11: UNKNOWN phase now hard-blocks with "SESSION CLOSED" — previously the
// engine issued TRADE signals at 2 PM, overnight, and on weekends.
void FinalDecision()
{
   state.decision = "NO TRADE";

   if(state.phase == UNKNOWN)
   {
      state.decision        = "SESSION CLOSED";
      state.risk_multiplier = 0.0;
      return;
   }

   if(state.no_trade_now)
   {
      state.decision        = "BLOCKED";
      state.risk_multiplier = 0.0;
      return;
   }

   if(!state.sweep_detected)     { state.decision = "WAIT SWEEP";        return; }
   if(!state.displacement_valid) { state.decision = "WAIT DISPLACEMENT"; return; }
   if(state.total_score < 65)    { state.decision = "SKIP";              return; }

   string dir = (state.direction == DIR_LONG)  ? " [LONG]"  :
                (state.direction == DIR_SHORT) ? " [SHORT]" : " [NO DIR]";

   state.decision = "TRADE" + dir;

   if(state.press_score  >= 80  &&
      state.fat_tail_active      &&
      state.smt_confirmed        &&
      state.quality == CLEAN)
   {
      state.decision        = "PRESS 2R" + dir;
      state.risk_multiplier = 2.0;
   }
}

//+------------------------------------------------------------------+
//| DASHBOARD                                                        |
//+------------------------------------------------------------------+
void RenderDashboard(datetime ny)
{
   string dir = (state.direction == DIR_LONG)  ? "LONG"  :
                (state.direction == DIR_SHORT) ? "SHORT" : "NONE";

   string txt = "";   // FIX: explicit init; MQL5 zeroes locals but intent is clear
   txt += "===== GRANDMASTER ENGINE v2.0 =====\n";
   txt += "TIME (NY):  " + TimeToString(ny, TIME_MINUTES) + "\n";
   txt += "\nPHASE:    " + EnumToString(state.phase);
   txt += "\nQUALITY:  " + EnumToString(state.quality);
   txt += "\nBIAS:     " + dir;
   txt += "\n\nSWEEP PDH: " + (string)state.sweep_pdh;
   txt += "\nSWEEP PDL:  " + (string)state.sweep_pdl;
   txt += "\nDISP:       " + (string)state.displacement_valid;
   txt += "\nMITIG:      " + (string)state.mitigation_valid;
   txt += "\n\nSMT:      " + IntegerToString(state.smt_score);
   txt += "\nFAT:      " + IntegerToString(state.fat_tail_score);
   txt += "\n\nTOTAL:    " + IntegerToString(state.total_score);
   txt += "\nNO TRD:   " + IntegerToString(state.no_trade_score);
   txt += "\nPRESS:    " + IntegerToString(state.press_score);
   txt += "\n\nDECISION: " + state.decision;
   txt += "\nRISK:     " + DoubleToString(state.risk_multiplier, 1) + "R";

   Comment(txt);
   // FIX #14a: Force immediate visual refresh after every state update
   ChartRedraw();
}
//+------------------------------------------------------------------+
