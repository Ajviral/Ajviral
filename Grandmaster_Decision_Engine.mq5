//+------------------------------------------------------------------+
//| ELITE GRANDMASTER DECISION ENGINE v2.0                          |
//| Institutional ICT/SMT Analysis System for MetaTrader 5          |
//| All Stage 2-5 upgrades + all 14 Stage-6 audit fixes integrated  |
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

// Fat tail raw weights — quality and displacement excluded to prevent compounding
// through the fat_tail -> total_score path (both are already scored directly).
// FIX-7 + FIX-8: W_FAT_QUAL and W_FAT_DISP intentionally removed from fat tail.
const double W_FAT_RANGE       = 10.0;
const double W_FAT_TIME        =  5.0;
const double MAX_FAT_RAW       = 15.0;          // W_FAT_RANGE + W_FAT_TIME only
const double FAT_ACTIVE_THRESH = 200.0 / 3.0;  // ~66.67 — 2/3-of-max gate on 0-100 scale

// Total score component weights
const double W_TOTAL_SWEEP      = 20.0;
const double W_TOTAL_DISP       = 20.0;
const double W_TOTAL_QUAL       = 10.0;
const double W_TOTAL_TIME       = 10.0;
const double W_TOTAL_MITIG      = 10.0;
const double W_TOTAL_SMT        = 15.0;
const double W_TOTAL_FAT        = 10.0;
const double MAX_TOTAL_RAW      = 95.0;
const double TOTAL_TRADE_THRESH = 68.4;   // 65/95 * 100

// Press score weights — independent of total_score, sum to 100.0
const double W_PRESS_FAT        = 30.0;
const double W_PRESS_SMT        = 25.0;
const double W_PRESS_QUAL       = 20.0;
const double W_PRESS_SWEEP      = 15.0;
const double W_PRESS_DISP       = 10.0;
const double PRESS_NO_TRADE_DED = 20.0;
const double PRESS_2R_THRESH    = 80.0;

// No-trade component weights — components sum to 100
const double W_NOTRADE_RANGE   = 25.0;
const double W_NOTRADE_CHOP    = 20.0;
const double W_NOTRADE_NODISP  = 15.0;
const double W_NOTRADE_NOSWEEP = 15.0;
const double W_NOTRADE_NOSMT   = 10.0;
const double W_NOTRADE_WINDOW  = 15.0;
const double NOTRADE_THRESH    = 60.0;

// FIX-9: ATR staleness threshold
const int ATR_STALE_SECONDS = 300;   // 5 minutes

//================ STATE =================//
struct MasterState
{
   MARKET_PHASE     phase;
   MARKET_QUALITY   quality;

   bool             no_trade_day;
   double           no_trade_score;   // 0-100

   bool             sweep_detected;
   TRADE_DIRECTION  sweep_direction;

   bool             displacement_valid;
   bool             mitigation_valid;

   int              smt_score;        // raw: 0, 8, or 15
   bool             smt_confirmed;

   double           fat_tail_score;   // normalized 0-100
   bool             fat_tail_active;

   double           total_score;      // normalized 0-100
   double           press_score;      // normalized 0-100, independent of total_score

   double           risk_multiplier;
   string           decision;
   TRADE_DIRECTION  direction;
};

MasterState state;

//================ GLOBALS =================//
int      ATR_Handle;
double   ATR_Buffer[];
double   ATR_Value;
datetime ATR_LastUpdate;   // FIX-9: staleness guard

double   PDH, PDL;
datetime last_bar_time;    // FIX-12: tracks M5 bar open time

// FIX-10: impulse origin cache for DetectMitigation
datetime g_impulse_time = 0;   // absolute time of cached impulse candle

//+------------------------------------------------------------------+
int OnInit()
{
   ZeroMemory(state);
   state.direction       = DIR_NONE;
   state.sweep_direction = DIR_NONE;
   state.phase           = UNKNOWN;
   state.quality         = MIXED;
   state.decision        = "INIT";

   ATR_LastUpdate  = 0;
   g_impulse_time  = 0;

   ATR_Handle = iATR(_Symbol, PERIOD_M5, ATR_Period);
   if(ATR_Handle == INVALID_HANDLE)
   {
      Alert("ELITE GRANDMASTER: ATR handle creation failed. Indicator disabled.");
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
   // FIX-12: evaluate once per M5 bar — prevents timing-score oscillation
   // across the 5 M1 sub-bars within each M5 bar
   if(!IsNewM5Bar()) return;

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

//================ UTIL =================//

// FIX-12: gate on M5 bar open time, not M1 minute, for scoring stability
bool IsNewM5Bar()
{
   datetime t = iTime(_Symbol, PERIOD_M5, 0);
   if(t == last_bar_time) return false;
   last_bar_time = t;
   return true;
}

//================ NY TIME (DST-AWARE) =================//
// US Eastern:
//   EDT (UTC-4): 2nd Sunday March  at 02:00 AM EST = 07:00 UTC
//   EST (UTC-5): 1st Sunday November at 02:00 AM EDT = 06:00 UTC
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
   int dow_mar1       = mar1_info.day_of_week;
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

//================ TIMING WEIGHT =================//
// FIX-6: smooth decay replaces the hard 9:45 timing cliff.
// Returns 0.0-1.0 quality factor for the NY kill zone window.
// Peak 1.0 during 9:30-9:40; linear decay to 0.0 by 9:55; zero outside.
double TimingWeight(datetime ny)
{
   MqlDateTime t; TimeToStruct(ny, t);
   if(t.hour != 9) return 0.0;
   int m = t.min;
   if(m < 30 || m > 55) return 0.0;
   if(m <= 40) return 1.0;
   return 1.0 - (double)(m - 40) / 15.0;   // linear decay from 9:40 to 9:55
}

//================ ATR =================//
// FIX-9: staleness guard — zero ATR_Value if no fresh read within threshold
void UpdateATR()
{
   if(ATR_Handle == INVALID_HANDLE) return;

   datetime now = TimeCurrent();
   if(CopyBuffer(ATR_Handle, 0, 0, 1, ATR_Buffer) > 0 && ATR_Buffer[0] > 0.0)
   {
      ATR_Value      = ATR_Buffer[0];
      ATR_LastUpdate = now;
   }
   else if(ATR_LastUpdate > 0 && (now - ATR_LastUpdate) > ATR_STALE_SECONDS)
   {
      ATR_Value = 0.0;   // stale — blocks all downstream scoring
   }
}

//================ MARKET =================//
void UpdateMarketPhase(datetime ny)
{
   MqlDateTime t; TimeToStruct(ny, t);

   if     (t.hour < 7)   state.phase = ACCUMULATION;
   else if(t.hour < 9)   state.phase = MANIPULATION;
   else if(t.hour <= 11) state.phase = EXPANSION;
   else                  state.phase = UNKNOWN;
}

void UpdateMarketQuality()
{
   // Closed M5 bars only — overlap ratio of consecutive bars 1-6
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
   if     (ratio < 0.3) state.quality = CLEAN;
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
   // Closed M5 bar (shift=1) only — never the forming bar
   double high  = iHigh (_Symbol, PERIOD_M5, 1);
   double low   = iLow  (_Symbol, PERIOD_M5, 1);
   double close = iClose(_Symbol, PERIOD_M5, 1);

   state.sweep_detected  = false;
   state.sweep_direction = DIR_NONE;

   if(high > PDH && close < PDH)
   {
      state.sweep_detected  = true;
      state.sweep_direction = DIR_SELL;   // grab above PDH -> expect reversal down
   }
   else if(low < PDL && close > PDL)
   {
      state.sweep_detected  = true;
      state.sweep_direction = DIR_BUY;    // grab below PDL -> expect reversal up
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

// Returns shift of the most recent M5 impulse candle (body > ATR*0.5) within [bar_from, bar_to].
// Minimum shift=2 guarantees origin is always older than the evaluation bar (shift=1).
int FindImpulseOrigin(int bar_from, int bar_to)
{
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

   // No sweep context — clear cache and exit
   if(!state.sweep_detected)
   {
      g_impulse_time = 0;
      return;
   }

   // FIX-10: reuse cached origin if its bar is still within the lookback window
   int origin = -1;
   if(g_impulse_time > 0)
   {
      for(int i = 2; i <= 8; i++)
         if(iTime(_Symbol, PERIOD_M5, i) == g_impulse_time) { origin = i; break; }
   }

   // Cache miss or aged out — fresh scan, then cache the result
   if(origin < 0)
   {
      origin = FindImpulseOrigin(2, 8);
      if(origin < 0) return;
      g_impulse_time = iTime(_Symbol, PERIOD_M5, origin);
   }

   double imp_open  = iOpen (_Symbol, PERIOD_M5, origin);
   double imp_close = iClose(_Symbol, PERIOD_M5, origin);
   double imp_range = MathAbs(imp_close - imp_open);
   if(imp_range <= 0.0) return;

   // FIX-2: impulse direction must align with sweep direction
   bool bullish_impulse = (imp_close > imp_open);
   if(state.sweep_direction == DIR_BUY  && !bullish_impulse) return;
   if(state.sweep_direction == DIR_SELL &&  bullish_impulse) return;

   // Evaluate bar 1 (most recent closed candle) retracement into impulse body
   double eval_close  = iClose(_Symbol, PERIOD_M5, 1);
   double retracement = 0.0;

   if(bullish_impulse)
   {
      if(eval_close >= imp_open && eval_close < imp_close)
         retracement = (imp_close - eval_close) / imp_range;
      else
         return;
   }
   else
   {
      if(eval_close > imp_close && eval_close <= imp_open)
         retracement = (eval_close - imp_close) / imp_range;
      else
         return;
   }

   // 20%-50%: valid order block retracement
   // >70%: structural failure (implicitly rejected by upper bound)
   state.mitigation_valid = (retracement >= 0.20 && retracement <= 0.50);
}

//================ SMT HELPERS =================//
bool SMTLoadSymbol(string sym)
{
   if(!SymbolSelect(sym, true)) return false;
   if(iBars(sym, PERIOD_M5) < 8) return false;
   return true;
}

// Time-sync helper: maps a self-symbol bar index to the correct bar index on the target symbol.
// Uses iBarShift to find the target bar whose open time matches the self bar's open time.
// Returns -1 if the matched bar is more than one M5 period (300 s) away from the expected time —
// this catches broker data gaps where iBarShift would otherwise silently return the wrong bar.
int SMTSyncShift(string target_sym, int self_shift)
{
   datetime bar_time = iTime(_Symbol, PERIOD_M5, self_shift);
   if(bar_time <= 0) return -1;
   int tgt = iBarShift(target_sym, PERIOD_M5, bar_time, false);
   if(tgt < 0) return -1;
   datetime matched = iTime(target_sym, PERIOD_M5, tgt);
   if(MathAbs((long)(matched - bar_time)) > 300) return -1;   // > 5-min gap = reject
   return tgt;
}

// Self-symbol swing helpers — read _Symbol directly by index (no sync needed on same symbol)
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

// Time-synchronized target-symbol swing helpers.
// Iterates over self-symbol bar indices, maps each to the corresponding target bar via
// SMTSyncShift(), then reads the target symbol's price at the time-correct index.
// Any bar where the target has a data gap (SMTSyncShift returns -1) is skipped entirely,
// preventing false divergence signals from misaligned broker data histories.
double SMTSwingLowSynced(string sym, int bar_from, int bar_to)
{
   double lo = DBL_MAX;
   for(int i = bar_from; i <= bar_to; i++)
   {
      int tgt = SMTSyncShift(sym, i);
      if(tgt < 0) continue;
      double v = iLow(sym, PERIOD_M5, tgt);
      if(v > 0.0 && v < lo) lo = v;
   }
   return (lo == DBL_MAX) ? 0.0 : lo;
}

double SMTSwingHighSynced(string sym, int bar_from, int bar_to)
{
   double hi = 0.0;
   for(int i = bar_from; i <= bar_to; i++)
   {
      int tgt = SMTSyncShift(sym, i);
      if(tgt < 0) continue;
      double v = iHigh(sym, PERIOD_M5, tgt);
      if(v > hi) hi = v;
   }
   return hi;
}

// Returns the self-symbol bar index at which the target symbol hit its swing low.
// Keeping this in self-symbol time allows the timing delta (td) calculation in
// UpdateSMT to remain a meaningful measure of how close in time the divergence occurred.
int SMTSwingLowBarSynced(string sym, int bar_from, int bar_to)
{
   double lo  = DBL_MAX;
   int    idx = bar_from;
   for(int i = bar_from; i <= bar_to; i++)
   {
      int tgt = SMTSyncShift(sym, i);
      if(tgt < 0) continue;
      double v = iLow(sym, PERIOD_M5, tgt);
      if(v > 0.0 && v < lo) { lo = v; idx = i; }
   }
   return idx;
}

int SMTSwingHighBarSynced(string sym, int bar_from, int bar_to)
{
   double hi  = 0.0;
   int    idx = bar_from;
   for(int i = bar_from; i <= bar_to; i++)
   {
      int tgt = SMTSyncShift(sym, i);
      if(tgt < 0) continue;
      double v = iHigh(sym, PERIOD_M5, tgt);
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

   // Target detection window : bars 1-3 (full divergence picture)
   // Self detection window   : bars 2-3 (FIX-5: bar 1 excluded — sweep bar corrupts self structure)
   // Reference window        : bars 4-6 (structural anchor for both assets)
   const int W1  = 1, W2  = 3;   // target
   const int SW1 = 2, SW2 = 3;   // self (sweep-bar-safe)
   const int R1  = 4, R2  = 6;   // reference

   // Target reads use time-synchronized helpers — maps self-symbol bar timestamps to the
   // correct target bar via iBarShift, rejecting any bar where the target has a data gap.
   double tgt_w_low   = SMTSwingLowSynced (target,  W1,  W2);
   double tgt_w_high  = SMTSwingHighSynced(target,  W1,  W2);
   double tgt_r_low   = SMTSwingLowSynced (target,  R1,  R2);
   double tgt_r_high  = SMTSwingHighSynced(target,  R1,  R2);

   // Self reads use direct index helpers — same symbol, no time-sync needed
   double self_w_low  = SMTSwingLow (_Symbol, SW1, SW2);
   double self_w_high = SMTSwingHigh(_Symbol, SW1, SW2);
   double self_r_low  = SMTSwingLow (_Symbol, R1,  R2);
   double self_r_high = SMTSwingHigh(_Symbol, R1,  R2);

   // Reject if any level is zero — incomplete data protection
   if(tgt_w_low  <= 0.0 || tgt_w_high  <= 0.0 ||
      tgt_r_low  <= 0.0 || tgt_r_high  <= 0.0 ||
      self_w_low <= 0.0 || self_w_high <= 0.0  ||
      self_r_low <= 0.0 || self_r_high <= 0.0) return;

   int tgt_low_bar   = SMTSwingLowBarSynced (target,  W1,  W2);
   int tgt_high_bar  = SMTSwingHighBarSynced(target,  W1,  W2);
   int self_low_bar  = SMTSwingLowBar       (_Symbol, SW1, SW2);
   int self_high_bar = SMTSwingHighBar      (_Symbol, SW1, SW2);

   int score = 0;

   if(!inverse)
   {
      // Correlated pair: both assets expected to make equivalent swings
      bool tgt_broke_low  = (tgt_w_low  < tgt_r_low);
      bool self_held_low  = (self_w_low >= self_r_low);
      bool tgt_broke_high = (tgt_w_high > tgt_r_high);
      bool self_held_high = (self_w_high <= self_r_high);

      if(tgt_broke_low && self_held_low)
      {
         int td = MathAbs(tgt_low_bar - self_low_bar);
         if     (td <= 1) score = 15;   // Strong
         else if(td <= 2) score = 8;    // Moderate
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
      // Inverse pair (e.g. GOLD / DXY): assets expected to move in opposite directions
      bool tgt_broke_high = (tgt_w_high > tgt_r_high);
      bool self_held_low  = (self_w_low >= self_r_low);
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
   state.smt_confirmed = (score >= 8);   // FIX-4: confirms on Moderate (8) and Strong (15)
}

//================ FAT TAIL =================//
void UpdateFatTailState(datetime ny)
{
   double raw   = 0.0;
   double range = iHigh(_Symbol, PERIOD_M5, 1) - iLow(_Symbol, PERIOD_M5, 1);

   if(range > ATR_Value) raw += W_FAT_RANGE;

   // FIX-6: smooth timing contribution — no hard cliff at 9:45
   raw += TimingWeight(ny) * W_FAT_TIME;

   // FIX-7+8: quality and displacement excluded — already scored directly in
   // total_score and press_score; including here creates compounding reward path

   state.fat_tail_score  = NormalizeFatTail(raw);
   state.fat_tail_active = (state.fat_tail_score >= FAT_ACTIVE_THRESH);
}

//================ NO TRADE =================//
void UpdateNoTradeState(datetime ny)
{
   double score = 0.0;
   double range = iHigh(_Symbol, PERIOD_M5, 1) - iLow(_Symbol, PERIOD_M5, 1);

   if(range < ATR_Value * 0.5)   score += W_NOTRADE_RANGE;
   if(state.quality == CHOP)     score += W_NOTRADE_CHOP;
   if(!state.displacement_valid) score += W_NOTRADE_NODISP;
   if(!state.sweep_detected)     score += W_NOTRADE_NOSWEEP;
   if(!state.smt_confirmed)      score += W_NOTRADE_NOSMT;

   // FIX-6: smooth timing penalty — zero at peak window, full at dead zones
   score += (1.0 - TimingWeight(ny)) * W_NOTRADE_WINDOW;

   state.no_trade_score = score;
   state.no_trade_day   = (score >= NOTRADE_THRESH);
}

//================ SCORING =================//
void CalculateScore(datetime ny)
{
   double raw = 0.0;

   if(state.sweep_detected)     raw += W_TOTAL_SWEEP;
   if(state.displacement_valid) raw += W_TOTAL_DISP;
   if(state.quality == CLEAN)   raw += W_TOTAL_QUAL;

   // FIX-6: smooth timing bonus scales with window quality
   raw += TimingWeight(ny) * W_TOTAL_TIME;

   if(state.mitigation_valid)   raw += W_TOTAL_MITIG;

   raw += (state.smt_score / 15.0)       * W_TOTAL_SMT;
   raw += (state.fat_tail_score / 100.0) * W_TOTAL_FAT;

   state.total_score = NormalizeTotal(raw);
}

//================ PRESS =================//
void CalculatePressScore(datetime ny)
{
   // Computed entirely from raw sub-components — zero dependency on total_score
   double score = 0.0;

   score += (state.fat_tail_score / 100.0) * W_PRESS_FAT;   // 0.0 - 30.0
   score += (state.smt_score / 15.0)       * W_PRESS_SMT;   // 0.0 - 25.0
   if(state.quality == CLEAN)    score += W_PRESS_QUAL;      // 0.0 or 20.0
   if(state.sweep_detected)      score += W_PRESS_SWEEP;     // 0.0 or 15.0
   if(state.displacement_valid)  score += W_PRESS_DISP;      // 0.0 or 10.0
   // raw max = 100.0

   if(state.no_trade_day) score -= PRESS_NO_TRADE_DED;

   state.press_score = ClampScore(score);
   // risk_multiplier assigned exclusively in FinalDecision
}

//================ FINAL DECISION =================//
void FinalDecision()
{
   state.decision        = "NO TRADE";
   state.direction       = DIR_NONE;
   state.risk_multiplier = 0.0;

   // FIX-11: zero press when blocked — prevents misleading high press display
   if(state.no_trade_day)
   {
      state.decision    = "BLOCKED";
      state.press_score = 0.0;
      return;
   }

   // FIX-1 (hardened): phase gate allows EXPANSION, but the kill zone (TimingWeight > 0)
   // is always tradeable regardless of phase — this prevents a 1-2 second broker clock
   // offset at the hour boundary from blocking a valid setup.
   // A setup at 9:30 AM remains fully accessible even if phase reads as MANIPULATION.
   bool in_trade_window = (state.phase == EXPANSION) || (TimingWeight(ny) > 0.0);
   if(!in_trade_window)
   {
      state.decision = "WAIT EXPANSION";
      return;
   }

   if(!state.sweep_detected)     { state.decision = "WAIT SWEEP";        return; }
   if(!state.displacement_valid) { state.decision = "WAIT DISPLACEMENT"; return; }

   if(state.total_score < TOTAL_TRADE_THRESH)
   {
      state.decision = "SKIP";
      return;
   }

   // Direction is derived exclusively from sweep type — single source of truth
   state.direction = state.sweep_direction;

   // FIX-3: non-PRESS-2R risk capped at 1.5x — 2.0x reserved for PRESS 2R only
   if     (state.press_score >= 80.0) state.risk_multiplier = 1.5;
   else if(state.press_score >= 65.0) state.risk_multiplier = 1.25;
   else if(state.press_score >= 50.0) state.risk_multiplier = 1.0;
   else                               state.risk_multiplier = 0.5;

   state.decision = "TRADE";

   // FIX-13: mitigation_valid added as PRESS 2R prerequisite — ensures
   // institutional entry precision before maximum size deployment
   if(state.press_score    >= PRESS_2R_THRESH &&
      state.fat_tail_active                   &&
      state.smt_confirmed                     &&
      state.quality         == CLEAN          &&
      state.mitigation_valid)
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

   // FIX-14: display prime window status alongside phase
   double tw = TimingWeight(ny);
   string window_str = (tw >= 0.99) ? "PRIME  [9:30-9:40]" :
                       (tw >= 0.50) ? "ACTIVE [9:40-9:47]" :
                       (tw >  0.0)  ? "DECAY  [9:47-9:55]" :
                                      "CLOSED";

   string sweep_detail = "";
   if(state.sweep_detected)
      sweep_detail = "  DIR: " + (state.sweep_direction == DIR_BUY ? "BUY" : "SELL");

   string txt = "====== ELITE GRANDMASTER ENGINE v2.0 ======\n";
   txt += "TIME:      " + TimeToString(ny, TIME_MINUTES) + "\n";
   txt += "\nPHASE:     " + EnumToString(state.phase);
   txt += "\nWINDOW:    " + window_str;
   txt += "\nQUALITY:   " + EnumToString(state.quality);
   txt += "\n";
   txt += "\nSWEEP:     " + (string)state.sweep_detected + sweep_detail;
   txt += "\nDISP:      " + (string)state.displacement_valid;
   txt += "\nMITIG:     " + (string)state.mitigation_valid;
   txt += "\n";
   txt += "\nSMT:       " + IntegerToString(state.smt_score)
        + "  [" + (state.smt_confirmed ? "CONFIRMED" : "WEAK") + "]";
   txt += "\nFAT TAIL:  " + DoubleToString(state.fat_tail_score, 1)
        + "  [" + (state.fat_tail_active ? "ACTIVE" : "IDLE") + "]";
   txt += "\n";
   txt += "\nTOTAL:     " + DoubleToString(state.total_score,    1)
        + " / " + DoubleToString(TOTAL_TRADE_THRESH, 1);
   txt += "\nNO TRADE:  " + DoubleToString(state.no_trade_score, 1)
        + " / " + DoubleToString(NOTRADE_THRESH,      1);
   txt += "\nPRESS:     " + DoubleToString(state.press_score,    1);
   txt += "\n";
   txt += "\nDECISION:  " + state.decision;
   txt += "\nDIRECTION: " + dir_str;
   txt += "\nRISK:      " + DoubleToString(state.risk_multiplier, 2) + "R";

   Comment(txt);
}
