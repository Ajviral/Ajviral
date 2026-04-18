//+------------------------------------------------------------------+
//| GRANDMASTER UNIFIED DECISION ENGINE v1.1                         |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property indicator_plots 0

//================ INPUTS =================//
input int    Timer_Seconds = 5;
input int    ATR_Period     = 14;

input string NAS100 = "NAS100";
input string US30   = "US30";
input string GOLD   = "XAUUSD";
input string DXY    = "USDX";

//================ ENUMS =================//
enum MARKET_PHASE    { ACCUMULATION, MANIPULATION, EXPANSION, UNKNOWN };
enum MARKET_QUALITY  { CLEAN, MIXED, CHOP };
enum TRADE_DIRECTION { DIR_NONE, DIR_BUY, DIR_SELL };

//================ SCORE CONSTANTS =================//

// Fat tail raw component weights — sum defines MAX_FAT_RAW
const double W_FAT_RANGE        = 10.0;
const double W_FAT_DISP         = 10.0;
const double W_FAT_QUAL         =  5.0;
const double W_FAT_TIME         =  5.0;
const double MAX_FAT_RAW        = 30.0;   // W_FAT_RANGE + W_FAT_DISP + W_FAT_QUAL + W_FAT_TIME
const double FAT_ACTIVE_THRESH  = 200.0 / 3.0;  // 20/30 * 100 — preserves original 2/3-of-max gate

// Total score component weights — sum defines MAX_TOTAL_RAW
const double W_TOTAL_SWEEP      = 20.0;
const double W_TOTAL_DISP       = 20.0;
const double W_TOTAL_QUAL       = 10.0;
const double W_TOTAL_TIME       = 10.0;
const double W_TOTAL_MITIG      = 10.0;
const double W_TOTAL_SMT        = 15.0;   // max raw SMT contribution (smt_score = 0 or 15)
const double W_TOTAL_FAT        = 10.0;   // fat_tail ceiling in total (= 1/3 of MAX_FAT_RAW)
const double MAX_TOTAL_RAW      = 95.0;   // sum of all W_TOTAL_*
const double TOTAL_TRADE_THRESH = 68.4;   // 65/95 * 100 — mathematically equivalent gate

// Press score independent weights — must sum to 100.0 with no reference to total_score
const double W_PRESS_FAT        = 30.0;
const double W_PRESS_SMT        = 25.0;
const double W_PRESS_QUAL       = 20.0;
const double W_PRESS_SWEEP      = 15.0;
const double W_PRESS_DISP       = 10.0;
const double PRESS_NO_TRADE_DED = 20.0;
const double PRESS_2R_THRESH    = 80.0;

// No-trade component weights — raw components already sum to 100; no normalization needed
const double W_NOTRADE_RANGE    = 25.0;
const double W_NOTRADE_CHOP     = 20.0;
const double W_NOTRADE_NODISP   = 15.0;
const double W_NOTRADE_NOSWEEP  = 15.0;
const double W_NOTRADE_NOSMT    = 10.0;
const double W_NOTRADE_WINDOW   = 15.0;
const double NOTRADE_THRESH     = 60.0;

//================ STATE =================//
struct MasterState
{
   MARKET_PHASE     phase;
   MARKET_QUALITY   quality;

   bool             no_trade_day;
   double           no_trade_score;   // 0–100, components already sum to 100

   bool             sweep_detected;
   TRADE_DIRECTION  sweep_direction;

   bool             displacement_valid;
   bool             mitigation_valid;

   int              smt_score;        // raw: 0 or 15 (kept int for direct display clarity)
   bool             smt_confirmed;

   double           fat_tail_score;   // normalized 0–100
   bool             fat_tail_active;

   double           total_score;      // normalized 0–100
   double           press_score;      // normalized 0–100, independent of total_score

   double           risk_multiplier;
   string           decision;
   TRADE_DIRECTION  direction;
};

MasterState state;

//================ GLOBALS =================//
int    ATR_Handle;
double ATR_Buffer[];
double ATR_Value;

double   PDH, PDL;
datetime last_bar_time;

//+------------------------------------------------------------------+
int OnInit()
{
   ZeroMemory(state);
   state.direction       = DIR_NONE;
   state.sweep_direction = DIR_NONE;
   state.phase           = UNKNOWN;
   state.quality         = MIXED;
   state.decision        = "INIT";

   ATR_Handle = iATR(_Symbol, PERIOD_M5, ATR_Period);
   if(ATR_Handle == INVALID_HANDLE)
   {
      Alert("GRANDMASTER: ATR handle creation failed. Indicator disabled.");
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
   if(ATR_Handle != INVALID_HANDLE)
      IndicatorRelease(ATR_Handle);
   Comment("");
}

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double   &open[],
                const double   &high[],
                const double   &low[],
                const double   &close[],
                const long     &tick_volume[],
                const long     &volume[],
                const int      &spread[])
{
   return rates_total;
}

//+------------------------------------------------------------------+
void OnTimer()
{
   if(!IsNewMinute()) return;

   datetime ny = GetNYTime();

   UpdateATR();
   if(ATR_Value <= 0.0) return;

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
   CalculatePressScore(ny);

   FinalDecision();

   RenderDashboard(ny);
}

//+------------------------------------------------------------------+

//================ UTIL =================//
bool IsNewMinute()
{
   datetime t = iTime(_Symbol, PERIOD_M1, 0);
   if(t == last_bar_time) return false;
   last_bar_time = t;
   return true;
}

//================ NY TIME (DST-AWARE) =================//
//
// US Eastern:
//   EDT (UTC-4): 2nd Sunday March  at 02:00 AM EST  = 07:00 UTC
//   EST (UTC-5): 1st Sunday November at 02:00 AM EDT = 06:00 UTC
//
datetime GetNYTime()
{
   datetime gmt = TimeGMT();

   MqlDateTime gmt_dt;
   TimeToStruct(gmt, gmt_dt);
   int year = gmt_dt.year;

   // Spring forward: 2nd Sunday of March at 07:00 UTC
   MqlDateTime mar1; ZeroMemory(mar1);
   mar1.year = year; mar1.mon = 3; mar1.day = 1;
   MqlDateTime mar1_info;
   TimeToStruct(StructToTime(mar1), mar1_info);
   int dow_mar1       = mar1_info.day_of_week;           // 0 = Sunday
   int first_sun_mar  = (dow_mar1 == 0) ? 1 : 1 + (7 - dow_mar1);
   int second_sun_mar = first_sun_mar + 7;

   MqlDateTime dst_start_dt; ZeroMemory(dst_start_dt);
   dst_start_dt.year = year; dst_start_dt.mon = 3;
   dst_start_dt.day  = second_sun_mar; dst_start_dt.hour = 7;
   datetime dst_start = StructToTime(dst_start_dt);

   // Fall back: 1st Sunday of November at 06:00 UTC
   MqlDateTime nov1; ZeroMemory(nov1);
   nov1.year = year; nov1.mon = 11; nov1.day = 1;
   MqlDateTime nov1_info;
   TimeToStruct(StructToTime(nov1), nov1_info);
   int dow_nov1      = nov1_info.day_of_week;
   int first_sun_nov = (dow_nov1 == 0) ? 1 : 1 + (7 - dow_nov1);

   MqlDateTime dst_end_dt; ZeroMemory(dst_end_dt);
   dst_end_dt.year = year; dst_end_dt.mon = 11;
   dst_end_dt.day  = first_sun_nov; dst_end_dt.hour = 6;
   datetime dst_end = StructToTime(dst_end_dt);

   int offset_hours = (gmt >= dst_start && gmt < dst_end) ? -4 : -5;
   return gmt + offset_hours * 3600;
}

//================ NORMALIZATION =================//

double NormalizeFatTail(double raw)
{
   return MathMin(MathMax(raw / MAX_FAT_RAW * 100.0, 0.0), 100.0);
}

double NormalizeTotal(double raw)
{
   return MathMin(MathMax(raw / MAX_TOTAL_RAW * 100.0, 0.0), 100.0);
}

double ClampScore(double score)
{
   return MathMin(MathMax(score, 0.0), 100.0);
}

//================ ATR =================//
void UpdateATR()
{
   if(ATR_Handle == INVALID_HANDLE) return;
   if(CopyBuffer(ATR_Handle, 0, 0, 1, ATR_Buffer) > 0 && ATR_Buffer[0] > 0.0)
      ATR_Value = ATR_Buffer[0];
}

//================ MARKET =================//
void UpdateMarketPhase(datetime ny)
{
   MqlDateTime t; TimeToStruct(ny, t);

   if(t.hour < 7)        state.phase = ACCUMULATION;
   else if(t.hour < 9)   state.phase = MANIPULATION;
   else if(t.hour <= 11) state.phase = EXPANSION;
   else                  state.phase = UNKNOWN;
}

void UpdateMarketQuality()
{
   // Closed M5 bars only — bars 1-6 vs 2-7
   int overlap = 0;
   for(int i = 1; i <= 5; i++)
   {
      double h  = iHigh(_Symbol, PERIOD_M5, i);
      double l  = iLow (_Symbol, PERIOD_M5, i);
      double ph = iHigh(_Symbol, PERIOD_M5, i + 1);
      double pl = iLow (_Symbol, PERIOD_M5, i + 1);
      if(l < ph && h > pl) overlap++;
   }
   double ratio = overlap / 5.0;
   if(ratio < 0.3)      state.quality = CLEAN;
   else if(ratio < 0.7) state.quality = MIXED;
   else                 state.quality = CHOP;
}

//================ STRUCTURE =================//
void UpdateDailyLevels()
{
   PDH = iHigh(_Symbol, PERIOD_D1, 1);
   PDL = iLow (_Symbol, PERIOD_D1, 1);
}

void DetectSweep()
{
   // Use last CLOSED M5 bar (shift = 1) — never the forming bar
   double high  = iHigh (_Symbol, PERIOD_M5, 1);
   double low   = iLow  (_Symbol, PERIOD_M5, 1);
   double close = iClose(_Symbol, PERIOD_M5, 1);

   state.sweep_detected  = false;
   state.sweep_direction = DIR_NONE;

   if(high > PDH && close < PDH)
   {
      state.sweep_detected  = true;
      state.sweep_direction = DIR_SELL;  // liquidity grab above PDH → expect reversal down
   }
   else if(low < PDL && close > PDL)
   {
      state.sweep_detected  = true;
      state.sweep_direction = DIR_BUY;   // liquidity grab below PDL → expect reversal up
   }
}

void DetectDisplacement()
{
   // M5 closed bar body vs M5 ATR — consistent timeframe throughout
   double body  = MathAbs(iClose(_Symbol, PERIOD_M5, 1) - iOpen(_Symbol, PERIOD_M5, 1));
   double range = iHigh (_Symbol, PERIOD_M5, 1) - iLow(_Symbol, PERIOD_M5, 1);
   state.displacement_valid = (range > 0.0 && body > ATR_Value * 0.5);
}

//================ MITIGATION HELPERS =================//

int FindImpulseOrigin(int bar_from, int bar_to)
{
   // Returns the shift of the most recent closed M5 candle whose body exceeds ATR * 0.5.
   // Iterates from most recent (bar_from) toward oldest (bar_to); shift >= 2 guarantees
   // the result is always a fully closed candle distinct from the evaluation bar (bar 1).
   for(int i = bar_from; i <= bar_to; i++)
   {
      double body  = MathAbs(iClose(_Symbol, PERIOD_M5, i) - iOpen(_Symbol, PERIOD_M5, i));
      double range = iHigh (_Symbol, PERIOD_M5, i) - iLow(_Symbol, PERIOD_M5, i);
      if(range > 0.0 && body > ATR_Value * 0.5)
         return i;
   }
   return -1;
}

//================ MITIGATION =================//
void DetectMitigation()
{
   state.mitigation_valid = false;

   // No mitigation is possible without a prior displacement candle in recent history
   int origin = FindImpulseOrigin(2, 8);
   if(origin < 0) return;

   double imp_open  = iOpen (_Symbol, PERIOD_M5, origin);
   double imp_close = iClose(_Symbol, PERIOD_M5, origin);
   double imp_range = MathAbs(imp_close - imp_open);
   if(imp_range <= 0.0) return;

   // Evaluate bar 1 (most recent closed candle) against the displacement body
   double eval_close  = iClose(_Symbol, PERIOD_M5, 1);
   double retracement = 0.0;

   if(imp_close > imp_open)   // bullish impulse — mitigation is price retracing back into the body
   {
      if(eval_close >= imp_open && eval_close < imp_close)
         retracement = (imp_close - eval_close) / imp_range;
      else
         return;
   }
   else                       // bearish impulse — mitigation is price bouncing back into the body
   {
      if(eval_close > imp_close && eval_close <= imp_open)
         retracement = (eval_close - imp_close) / imp_range;
      else
         return;
   }

   // Valid:    20%–50% — price is inside the displacement order block zone
   // Rejected: >70%   — price has retraced so deeply that structural integrity is broken
   state.mitigation_valid = (retracement >= 0.20 && retracement <= 0.50);
}

//================ SMT HELPERS =================//

bool SMTLoadSymbol(string sym)
{
   if(!SymbolSelect(sym, true)) return false;
   if(iBars(sym, PERIOD_M5) < 8) return false;
   return true;
}

double SMTSwingLow(string sym, int bar_from, int bar_to)
{
   double lo = DBL_MAX;
   for(int i = bar_from; i <= bar_to; i++)
   {
      double v = iLow(sym, PERIOD_M5, i);
      if(v > 0.0 && v < lo) lo = v;
   }
   return (lo == DBL_MAX) ? 0.0 : lo;
}

double SMTSwingHigh(string sym, int bar_from, int bar_to)
{
   double hi = 0.0;
   for(int i = bar_from; i <= bar_to; i++)
   {
      double v = iHigh(sym, PERIOD_M5, i);
      if(v > hi) hi = v;
   }
   return hi;
}

int SMTSwingLowBar(string sym, int bar_from, int bar_to)
{
   double lo  = DBL_MAX;
   int    idx = bar_from;
   for(int i = bar_from; i <= bar_to; i++)
   {
      double v = iLow(sym, PERIOD_M5, i);
      if(v > 0.0 && v < lo) { lo = v; idx = i; }
   }
   return idx;
}

int SMTSwingHighBar(string sym, int bar_from, int bar_to)
{
   double hi  = 0.0;
   int    idx = bar_from;
   for(int i = bar_from; i <= bar_to; i++)
   {
      double v = iHigh(sym, PERIOD_M5, i);
      if(v > hi) { hi = v; idx = i; }
   }
   return idx;
}

//================ SMT =================//
void UpdateSMT()
{
   state.smt_score     = 0;
   state.smt_confirmed = false;

   string target  = "";
   bool   inverse = false;

   if     (_Symbol == NAS100) target = US30;
   else if(_Symbol == US30)   target = NAS100;
   else if(_Symbol == GOLD) { target = DXY; inverse = true; }

   if(target == "") return;
   if(!SMTLoadSymbol(target)) return;

   // Detection window : bars 1–3 (closed candles, timing alignment zone)
   // Reference window : bars 4–6 (structural anchor for divergence comparison)
   const int W1 = 1, W2 = 3;
   const int R1 = 4, R2 = 6;

   double tgt_w_low   = SMTSwingLow (target,   W1, W2);
   double tgt_w_high  = SMTSwingHigh(target,   W1, W2);
   double tgt_r_low   = SMTSwingLow (target,   R1, R2);
   double tgt_r_high  = SMTSwingHigh(target,   R1, R2);

   double self_w_low  = SMTSwingLow (_Symbol,  W1, W2);
   double self_w_high = SMTSwingHigh(_Symbol,  W1, W2);
   double self_r_low  = SMTSwingLow (_Symbol,  R1, R2);
   double self_r_high = SMTSwingHigh(_Symbol,  R1, R2);

   // Reject on any zero/missing level — prevents false signals from incomplete data
   if(tgt_w_low  <= 0.0 || tgt_w_high  <= 0.0 ||
      tgt_r_low  <= 0.0 || tgt_r_high  <= 0.0 ||
      self_w_low <= 0.0 || self_w_high  <= 0.0 ||
      self_r_low <= 0.0 || self_r_high  <= 0.0) return;

   int tgt_low_bar   = SMTSwingLowBar (target,   W1, W2);
   int tgt_high_bar  = SMTSwingHighBar(target,   W1, W2);
   int self_low_bar  = SMTSwingLowBar (_Symbol,  W1, W2);
   int self_high_bar = SMTSwingHighBar(_Symbol,  W1, W2);

   int score = 0;

   if(!inverse)
   {
      // Correlated pair — both assets are expected to make equivalent swings
      //
      // Bullish structural divergence:
      //   target broke below its reference low; self held above its reference low
      bool tgt_broke_low  = (tgt_w_low  < tgt_r_low);
      bool self_held_low  = (self_w_low >= self_r_low);

      // Bearish structural divergence:
      //   target broke above its reference high; self failed to follow
      bool tgt_broke_high = (tgt_w_high > tgt_r_high);
      bool self_held_high = (self_w_high <= self_r_high);

      if(tgt_broke_low && self_held_low)
      {
         int td = MathAbs(tgt_low_bar - self_low_bar);
         if     (td <= 1) score = 15;   // same or adjacent bar → Strong
         else if(td <= 2) score = 8;    // 2-bar gap → Moderate
      }
      else if(tgt_broke_high && self_held_high)
      {
         int td = MathAbs(tgt_high_bar - self_high_bar);
         if     (td <= 1) score = 15;
         else if(td <= 2) score = 8;
      }
   }
   else
   {
      // Inverse pair (e.g. GOLD / DXY) — assets expected to move in opposite directions
      //
      // Bullish self SMT:
      //   target (DXY) broke above its reference high; self (GOLD) failed to break its reference low
      bool tgt_broke_high = (tgt_w_high > tgt_r_high);
      bool self_held_low  = (self_w_low >= self_r_low);

      // Bearish self SMT:
      //   target (DXY) broke below its reference low; self (GOLD) failed to break its reference high
      bool tgt_broke_low  = (tgt_w_low  < tgt_r_low);
      bool self_held_high = (self_w_high <= self_r_high);

      if(tgt_broke_high && self_held_low)
      {
         int td = MathAbs(tgt_high_bar - self_low_bar);
         if     (td <= 1) score = 15;
         else if(td <= 2) score = 8;
      }
      else if(tgt_broke_low && self_held_high)
      {
         int td = MathAbs(tgt_low_bar - self_high_bar);
         if     (td <= 1) score = 15;
         else if(td <= 2) score = 8;
      }
   }

   state.smt_score     = score;
   state.smt_confirmed = (score >= 10);
}

//================ FAT TAIL =================//
void UpdateFatTailState(datetime ny)
{
   double raw   = 0.0;
   double range = iHigh(_Symbol, PERIOD_M5, 1) - iLow(_Symbol, PERIOD_M5, 1);

   if(range > ATR_Value)        raw += W_FAT_RANGE;
   if(state.displacement_valid) raw += W_FAT_DISP;
   if(state.quality == CLEAN)   raw += W_FAT_QUAL;

   MqlDateTime t; TimeToStruct(ny, t);
   if(t.hour == 9 && t.min <= 40) raw += W_FAT_TIME;

   state.fat_tail_score  = NormalizeFatTail(raw);            // 0–100
   state.fat_tail_active = (state.fat_tail_score >= FAT_ACTIVE_THRESH);  // same 2/3-of-max gate
}

//================ NO TRADE =================//
void UpdateNoTradeState(datetime ny)
{
   double score = 0.0;
   double range = iHigh(_Symbol, PERIOD_M5, 1) - iLow(_Symbol, PERIOD_M5, 1);

   if(range < ATR_Value * 0.5)    score += W_NOTRADE_RANGE;
   if(state.quality == CHOP)      score += W_NOTRADE_CHOP;
   if(!state.displacement_valid)  score += W_NOTRADE_NODISP;
   if(!state.sweep_detected)      score += W_NOTRADE_NOSWEEP;
   if(!state.smt_confirmed)       score += W_NOTRADE_NOSMT;

   MqlDateTime t; TimeToStruct(ny, t);
   if(!(t.hour == 9 && t.min >= 30 && t.min <= 45)) score += W_NOTRADE_WINDOW;

   state.no_trade_score = score;                      // 0–100, components sum to exactly 100
   state.no_trade_day   = (score >= NOTRADE_THRESH);
}

//================ SCORING =================//
void CalculateScore(datetime ny)
{
   double raw = 0.0;

   if(state.sweep_detected)      raw += W_TOTAL_SWEEP;
   if(state.displacement_valid)  raw += W_TOTAL_DISP;
   if(state.quality == CLEAN)    raw += W_TOTAL_QUAL;

   MqlDateTime t; TimeToStruct(ny, t);
   if(t.hour == 9 && t.min >= 30 && t.min <= 45) raw += W_TOTAL_TIME;

   if(state.mitigation_valid)    raw += W_TOTAL_MITIG;

   // SMT: exact fractional contribution — no integer truncation
   raw += (state.smt_score / 15.0) * W_TOTAL_SMT;

   // Fat tail: passes through its normalized 0–100 value scaled to its weight ceiling
   // Eliminates the integer division truncation of the former fat_tail_score / 3
   raw += (state.fat_tail_score / 100.0) * W_TOTAL_FAT;

   state.total_score = NormalizeTotal(raw);           // 0–100
}

//================ PRESS =================//
void CalculatePressScore(datetime ny)
{
   // Computed entirely from raw components — zero dependency on total_score.
   // W_PRESS_* weights sum to 100.0, making the score range [0, 100] before deduction.
   double score = 0.0;

   score += (state.fat_tail_score / 100.0) * W_PRESS_FAT;  // 0.0 – 30.0
   score += (state.smt_score / 15.0)       * W_PRESS_SMT;  // 0.0 – 25.0
   if(state.quality == CLEAN)    score += W_PRESS_QUAL;     // 0.0 or 20.0
   if(state.sweep_detected)      score += W_PRESS_SWEEP;    // 0.0 or 15.0
   if(state.displacement_valid)  score += W_PRESS_DISP;     // 0.0 or 10.0
   // raw max = 100.0

   if(state.no_trade_day) score -= PRESS_NO_TRADE_DED;

   state.press_score = ClampScore(score);                   // 0–100
   // risk_multiplier is assigned exclusively in FinalDecision
}

//================ FINAL DECISION =================//
void FinalDecision()
{
   state.decision        = "NO TRADE";
   state.direction       = DIR_NONE;
   state.risk_multiplier = 0.0;

   if(state.no_trade_day)
   {
      state.decision = "BLOCKED";
      return;
   }

   if(!state.sweep_detected)     { state.decision = "WAIT SWEEP";        return; }
   if(!state.displacement_valid) { state.decision = "WAIT DISPLACEMENT"; return; }

   if(state.total_score < TOTAL_TRADE_THRESH)
   {
      state.decision = "SKIP";
      return;
   }

   // Direction derived from sweep type — single source of truth
   state.direction = state.sweep_direction;

   // Single authoritative risk assignment — not set anywhere else
   if     (state.press_score >= 80.0) state.risk_multiplier = 2.0;
   else if(state.press_score >= 65.0) state.risk_multiplier = 1.5;
   else if(state.press_score >= 50.0) state.risk_multiplier = 1.0;
   else                               state.risk_multiplier = 0.5;

   state.decision = "TRADE";

   if(state.press_score >= PRESS_2R_THRESH &&
      state.fat_tail_active                &&
      state.smt_confirmed                  &&
      state.quality == CLEAN)
   {
      state.decision        = "PRESS 2R";
      state.risk_multiplier = 2.0;
   }
}

//================ UI =================//
void RenderDashboard(datetime ny)
{
   string dir_str;
   switch(state.direction)
   {
      case DIR_BUY:  dir_str = "BUY";  break;
      case DIR_SELL: dir_str = "SELL"; break;
      default:       dir_str = "NONE"; break;
   }

   string txt = "===== GRANDMASTER ENGINE =====\n";
   txt += "TIME: "       + TimeToString(ny, TIME_MINUTES) + "\n";
   txt += "\nPHASE: "    + EnumToString(state.phase);
   txt += "\nQUALITY: "  + EnumToString(state.quality);
   txt += "\n\nSWEEP: "  + (string)state.sweep_detected;
   txt += "\nDISP: "     + (string)state.displacement_valid;
   txt += "\nMITIG: "    + (string)state.mitigation_valid;
   txt += "\n\nSMT: "    + IntegerToString(state.smt_score);
   txt += "\nFAT: "      + DoubleToString(state.fat_tail_score, 1);
   txt += "\n\nTOTAL: "   + DoubleToString(state.total_score,    1);
   txt += "\nNO TRADE: " + DoubleToString(state.no_trade_score,  1);
   txt += "\nPRESS: "    + DoubleToString(state.press_score,     1);
   txt += "\n\nDECISION: "  + state.decision;
   txt += "\nDIRECTION: "   + dir_str;
   txt += "\nRISK: "        + DoubleToString(state.risk_multiplier, 1);

   Comment(txt);
}
