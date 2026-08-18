//+------------------------------------------------------------------+
//| ELITE GRANDMASTER DECISION ENGINE v3.0                          |
//| Institutional ICT/SMT Analysis System for MetaTrader 5          |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property indicator_plots 0

input int    Timer_Seconds      = 5;
input int    ATR_Period         = 14;
input int    Leg_Bars           = 12;
input bool   Use_Volume         = true;
input int    Volume_Bars        = 5;
input double Volume_Spike_Ratio = 1.5;
input int    Archetype_Bars     = 20;
input double Compression_Ratio  = 0.75;
input double HTF_Proximity_ATR  = 2.0;
input double Min_RR_Trade       = 2.0;
input double Min_RR_Press       = 3.0;
input string NAS100 = "NAS100";
input string US30   = "US30";
input string GOLD   = "XAUUSD";
input string DXY    = "USDX";

enum MARKET_PHASE      { ACCUMULATION, MANIPULATION, EXPANSION, UNKNOWN };
enum MARKET_QUALITY    { CLEAN, MIXED, CHOP };
enum TRADE_DIRECTION   { DIR_NONE, DIR_BUY, DIR_SELL };
enum SESSION_ARCHETYPE { ARCH_EXPANSION, ARCH_PROBE, ARCH_BALANCE };

const double W_FAT_RANGE       = 10.0;
const double W_FAT_TIME        =  5.0;
const double MAX_FAT_RAW       = 15.0;
const double FAT_ACTIVE_THRESH = 200.0 / 3.0;

const double W_TOTAL_SWEEP      = 20.0;
const double W_TOTAL_DISP       = 20.0;
const double W_TOTAL_QUAL       = 10.0;
const double W_TOTAL_TIME       = 10.0;
const double W_TOTAL_MITIG      = 10.0;
const double W_TOTAL_SMT        = 15.0;
const double W_TOTAL_FAT        = 10.0;
const double MAX_TOTAL_RAW      = 95.0;
const double TOTAL_TRADE_THRESH = 68.4;

const double W_PRESS_FAT        = 30.0;
const double W_PRESS_SMT        = 25.0;
const double W_PRESS_QUAL       = 20.0;
const double W_PRESS_SWEEP      = 15.0;
const double W_PRESS_DISP       = 10.0;
const double W_PRESS_VOL        = 10.0;
const double PRESS_NO_TRADE_DED = 20.0;
const double PRESS_2R_THRESH    = 80.0;

const double W_NOTRADE_RANGE   = 25.0;
const double W_NOTRADE_CHOP    = 20.0;
const double W_NOTRADE_NODISP  = 15.0;
const double W_NOTRADE_NOSWEEP = 15.0;
const double W_NOTRADE_NOSMT   = 10.0;
const double W_NOTRADE_WINDOW  = 15.0;
const double NOTRADE_THRESH    = 60.0;

const int    ATR_STALE_SECONDS = 300;
const double MIN_LEG_ATR_RATIO = 0.3;

struct MasterState
{
   MARKET_PHASE      phase;
   MARKET_QUALITY    quality;
   SESSION_ARCHETYPE archetype;
   bool              no_trade_day;
   double            no_trade_score;
   bool              sweep_detected;
   TRADE_DIRECTION   sweep_direction;
   bool              displacement_valid;
   bool              volume_confirmed;
   bool              mitigation_valid;
   int               mitigation_touch;
   bool              hierarchy_approved;
   double            liquidity_target;
   double            computed_rr;
   int               smt_score;
   bool              smt_confirmed;
   double            fat_tail_score;
   bool              fat_tail_active;
   double            total_score;
   double            press_score;
   double            risk_multiplier;
   string            decision;
   TRADE_DIRECTION   direction;
};

MasterState     state;
int             ATR_Handle;
double          ATR_Buffer[];
double          ATR_Value;
datetime        ATR_LastUpdate;
double          PDH, PDL;
datetime        last_bar_time;
int             g_sweep_persist;
TRADE_DIRECTION g_sweep_dir_cache;
int             g_leg_bars;
int             g_sweep_persist_bars;
double          g_leg_extreme_price;
int             g_mitigation_count;
bool            g_mitigation_was_valid;

//+------------------------------------------------------------------+
int OnInit()
{
   ZeroMemory(state);
   state.direction          = DIR_NONE;
   state.sweep_direction    = DIR_NONE;
   state.phase              = UNKNOWN;
   state.quality            = MIXED;
   state.archetype          = ARCH_PROBE;
   state.hierarchy_approved = true;
   state.decision           = "INIT";
   ATR_LastUpdate           = 0;
   g_sweep_persist          = 0;
   g_sweep_dir_cache        = DIR_NONE;
   g_leg_extreme_price      = 0.0;
   g_mitigation_count       = 0;
   g_mitigation_was_valid   = false;

   g_leg_bars           = MathMax(Leg_Bars, 4);
   g_sweep_persist_bars = MathMax(g_leg_bars - 2, 2);

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
   if(ATR_Handle != INVALID_HANDLE) IndicatorRelease(ATR_Handle);
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
   if(!IsNewM5Bar()) return;

   datetime ny = GetNYTime();

   UpdateATR();
   if(ATR_Value <= 0.0) return;

   UpdateDailyLevels();
   ClassifySessionArchetype();
   UpdateMarketPhase(ny);
   UpdateMarketQuality();
   DetectSweep();
   DetectDisplacement();
   DetectMitigation();
   UpdateLiquidityTarget();
   UpdateSMT();
   CheckAssetHierarchy();
   UpdateFatTailState(ny);
   UpdateNoTradeState(ny);
   CalculateScore(ny);
   CalculatePressScore();
   FinalDecision(ny);
   RenderDashboard(ny);
}

//+------------------------------------------------------------------+
bool IsNewM5Bar()
{
   datetime t = iTime(_Symbol, PERIOD_M5, 0);
   if(t == last_bar_time) return false;
   last_bar_time = t;
   return true;
}

//+------------------------------------------------------------------+
datetime GetNYTime()
{
   datetime gmt = TimeGMT();
   MqlDateTime gmt_dt;
   TimeToStruct(gmt, gmt_dt);
   int year = gmt_dt.year;

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

//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
double TimingWeight(datetime ny)
{
   MqlDateTime t; TimeToStruct(ny, t);
   if(t.hour != 9) return 0.0;
   int m = t.min;
   if(m < 30 || m > 55) return 0.0;
   if(m <= 40) return 1.0;
   return 1.0 - (double)(m - 40) / 15.0;
}

//+------------------------------------------------------------------+
bool PastAssetCutoff(datetime ny)
{
   MqlDateTime t; TimeToStruct(ny, t);
   if(t.hour < 9)  return false;
   if(t.hour > 9)  return true;
   if(_Symbol == NAS100) return (t.min > 42);
   if(_Symbol == US30)   return (t.min > 40);
   if(_Symbol == GOLD)   return (t.min > 45);
   return (t.min > 55);
}

//+------------------------------------------------------------------+
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
      ATR_Value = 0.0;
   }
}

//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
void UpdateDailyLevels()
{
   PDH = iHigh(_Symbol, PERIOD_D1, 1);
   PDL = iLow (_Symbol, PERIOD_D1, 1);
}

//+------------------------------------------------------------------+
void ClassifySessionArchetype()
{
   double prior_range = PDH - PDL;
   if(prior_range <= 0.0) { state.archetype = ARCH_PROBE; return; }

   double avg_range = 0.0;
   int    count     = 0;
   for(int i = 2; i <= Archetype_Bars + 1; i++)
   {
      double h = iHigh(_Symbol, PERIOD_D1, i);
      double l = iLow (_Symbol, PERIOD_D1, i);
      if(h > 0.0 && l > 0.0 && h > l) { avg_range += (h - l); count++; }
   }
   if(count == 0) { state.archetype = ARCH_PROBE; return; }
   avg_range /= count;

   bool compressed = (prior_range / avg_range < Compression_Ratio);

   double weekly_high = iHigh(_Symbol, PERIOD_W1, 1);
   double weekly_low  = iLow (_Symbol, PERIOD_W1, 1);
   double cur_close   = iClose(_Symbol, PERIOD_M5, 1);
   double proximity   = ATR_Value * HTF_Proximity_ATR;
   bool   near_htf    = (MathAbs(cur_close - weekly_high) <= proximity ||
                         MathAbs(cur_close - weekly_low)  <= proximity);

   if     (compressed && near_htf)  state.archetype = ARCH_EXPANSION;
   else if(compressed || near_htf)  state.archetype = ARCH_PROBE;
   else                             state.archetype = ARCH_BALANCE;
}

//+------------------------------------------------------------------+
void DetectSweep()
{
   double high  = iHigh (_Symbol, PERIOD_M5, 1);
   double low   = iLow  (_Symbol, PERIOD_M5, 1);
   double close = iClose(_Symbol, PERIOD_M5, 1);

   if(high > PDH && close < PDH)
   {
      g_sweep_persist        = g_sweep_persist_bars;
      g_sweep_dir_cache      = DIR_SELL;
      g_mitigation_count     = 0;
      g_mitigation_was_valid = false;
      g_leg_extreme_price    = 0.0;
   }
   else if(low < PDL && close > PDL)
   {
      g_sweep_persist        = g_sweep_persist_bars;
      g_sweep_dir_cache      = DIR_BUY;
      g_mitigation_count     = 0;
      g_mitigation_was_valid = false;
      g_leg_extreme_price    = 0.0;
   }
   else
   {
      if(g_sweep_persist > 0) g_sweep_persist--;
      if(g_sweep_persist == 0)
      {
         g_sweep_dir_cache      = DIR_NONE;
         g_mitigation_count     = 0;
         g_mitigation_was_valid = false;
         g_leg_extreme_price    = 0.0;
      }
   }

   state.sweep_detected  = (g_sweep_persist > 0);
   state.sweep_direction = (g_sweep_persist > 0) ? g_sweep_dir_cache : DIR_NONE;
}

//+------------------------------------------------------------------+
bool CheckVolumeSpike(int disp_bar)
{
   if(!Use_Volume) return false;
   long disp_vol = iVolume(_Symbol, PERIOD_M5, disp_bar);
   if(disp_vol <= 0) return false;

   double avg_vol = 0.0;
   int    count   = 0;
   for(int i = disp_bar + 1; i <= disp_bar + Volume_Bars; i++)
   {
      long v = iVolume(_Symbol, PERIOD_M5, i);
      if(v > 0) { avg_vol += v; count++; }
   }
   if(count == 0) return false;
   avg_vol /= count;

   return (disp_vol >= avg_vol * Volume_Spike_Ratio);
}

//+------------------------------------------------------------------+
void DetectDisplacement()
{
   state.displacement_valid = false;
   state.volume_confirmed   = false;
   if(!state.sweep_detected) return;

   for(int i = 1; i <= g_sweep_persist_bars; i++)
   {
      double body  = MathAbs(iClose(_Symbol, PERIOD_M5, i) - iOpen(_Symbol, PERIOD_M5, i));
      double range = iHigh (_Symbol, PERIOD_M5, i) - iLow(_Symbol, PERIOD_M5, i);
      if(range <= 0.0 || body <= ATR_Value * 0.5) continue;

      double c = iClose(_Symbol, PERIOD_M5, i);
      double o = iOpen (_Symbol, PERIOD_M5, i);

      if(state.sweep_direction == DIR_BUY  && c > o)
      {
         state.displacement_valid = true;
         state.volume_confirmed   = CheckVolumeSpike(i);
         return;
      }
      if(state.sweep_direction == DIR_SELL && c < o)
      {
         state.displacement_valid = true;
         state.volume_confirmed   = CheckVolumeSpike(i);
         return;
      }
   }
}

//+------------------------------------------------------------------+
bool EvaluateMitigation()
{
   double leg_extreme = 0.0;
   double leg_counter = 0.0;
   int    extreme_bar = -1;

   if(state.sweep_direction == DIR_BUY)
   {
      double lo = DBL_MAX;
      for(int i = 1; i <= g_leg_bars; i++)
      {
         double v = iLow(_Symbol, PERIOD_M5, i);
         if(v > 0.0 && v < lo) { lo = v; extreme_bar = i; }
      }
      if(extreme_bar < 2) return false;
      leg_extreme = lo;

      double hi = 0.0;
      for(int i = 1; i < extreme_bar; i++)
      {
         double v = iHigh(_Symbol, PERIOD_M5, i);
         if(v > hi) hi = v;
      }
      if(hi <= 0.0) return false;
      leg_counter = hi;
   }
   else
   {
      double hi = 0.0;
      for(int i = 1; i <= g_leg_bars; i++)
      {
         double v = iHigh(_Symbol, PERIOD_M5, i);
         if(v > hi) { hi = v; extreme_bar = i; }
      }
      if(extreme_bar < 2) return false;
      leg_extreme = hi;

      double lo = DBL_MAX;
      for(int i = 1; i < extreme_bar; i++)
      {
         double v = iLow(_Symbol, PERIOD_M5, i);
         if(v > 0.0 && v < lo) lo = v;
      }
      if(lo == DBL_MAX) return false;
      leg_counter = lo;
   }

   double leg_range = MathAbs(leg_counter - leg_extreme);
   if(leg_range < ATR_Value * MIN_LEG_ATR_RATIO) return false;

   g_leg_extreme_price = leg_extreme;

   double eval_close  = iClose(_Symbol, PERIOD_M5, 1);
   double retracement = 0.0;

   if(state.sweep_direction == DIR_BUY)
   {
      if(eval_close <= leg_extreme || eval_close >= leg_counter) return false;
      retracement = (leg_counter - eval_close) / leg_range;
      if(eval_close < PDL) return false;
   }
   else
   {
      if(eval_close >= leg_extreme || eval_close <= leg_counter) return false;
      retracement = (eval_close - leg_counter) / leg_range;
      if(eval_close > PDH) return false;
   }

   return (retracement >= 0.15 && retracement <= 0.65);
}

void DetectMitigation()
{
   state.mitigation_valid = false;
   state.mitigation_touch = 0;
   if(!state.sweep_detected) return;

   state.mitigation_valid = EvaluateMitigation();

   if(state.mitigation_valid && !g_mitigation_was_valid) g_mitigation_count++;
   g_mitigation_was_valid = state.mitigation_valid;
   state.mitigation_touch = g_mitigation_count;
}

//+------------------------------------------------------------------+
void UpdateLiquidityTarget()
{
   state.liquidity_target = 0.0;
   state.computed_rr      = 0.0;

   if(g_leg_extreme_price <= 0.0)        return;
   if(state.sweep_direction == DIR_NONE) return;

   double current   = iClose(_Symbol, PERIOD_M5, 1);
   double stop_dist = MathAbs(current - g_leg_extreme_price);
   if(stop_dist < _Point) return;

   double target      = 0.0;
   double target_dist = 0.0;

   if(state.sweep_direction == DIR_BUY)
   {
      target = PDH;
      if(target <= current) return;
      target_dist = target - current;
   }
   else
   {
      target = PDL;
      if(target >= current) return;
      target_dist = current - target;
   }

   state.liquidity_target = target;
   state.computed_rr      = target_dist / stop_dist;
}

//+------------------------------------------------------------------+
bool SMTLoadSymbol(string sym)
{
   if(!SymbolSelect(sym, true)) return false;
   if(iBars(sym, PERIOD_M5) < g_leg_bars + 2) return false;
   return true;
}

int SMTSyncShift(string target_sym, int self_shift)
{
   datetime bar_time = iTime(_Symbol, PERIOD_M5, self_shift);
   if(bar_time <= 0) return -1;
   int tgt = iBarShift(target_sym, PERIOD_M5, bar_time, false);
   if(tgt < 0) return -1;
   datetime matched = iTime(target_sym, PERIOD_M5, tgt);
   if(MathAbs((long)(matched - bar_time)) > 300) return -1;
   return tgt;
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

//+------------------------------------------------------------------+
TRADE_DIRECTION GetIndexBias(string sym)
{
   if(!SMTLoadSymbol(sym)) return DIR_NONE;
   double h       = iHigh (sym, PERIOD_M5, 1);
   double l       = iLow  (sym, PERIOD_M5, 1);
   double c       = iClose(sym, PERIOD_M5, 1);
   double sym_pdh = iHigh (sym, PERIOD_D1, 1);
   double sym_pdl = iLow  (sym, PERIOD_D1, 1);
   if(h > sym_pdh && c < sym_pdh) return DIR_SELL;
   if(l < sym_pdl && c > sym_pdl) return DIR_BUY;
   return DIR_NONE;
}

void CheckAssetHierarchy()
{
   state.hierarchy_approved = true;
   if(_Symbol == GOLD)                    return;
   if(state.sweep_direction == DIR_NONE)  return;

   string peer = "";
   if     (_Symbol == NAS100) peer = US30;
   else if(_Symbol == US30)   peer = NAS100;
   if(peer == "")                         return;

   TRADE_DIRECTION peer_bias = GetIndexBias(peer);
   if(peer_bias == DIR_NONE)              return;

   if(peer_bias != state.sweep_direction)
      state.hierarchy_approved = false;
}

//+------------------------------------------------------------------+
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

   const int W1  = 1, W2  = 3;
   const int SW1 = 2, SW2 = 3;
   const int R1  = 4, R2  = 6;

   double tgt_w_low   = SMTSwingLowSynced (target,  W1,  W2);
   double tgt_w_high  = SMTSwingHighSynced(target,  W1,  W2);
   double tgt_r_low   = SMTSwingLowSynced (target,  R1,  R2);
   double tgt_r_high  = SMTSwingHighSynced(target,  R1,  R2);
   double self_w_low  = SMTSwingLow (_Symbol, SW1, SW2);
   double self_w_high = SMTSwingHigh(_Symbol, SW1, SW2);
   double self_r_low  = SMTSwingLow (_Symbol, R1,  R2);
   double self_r_high = SMTSwingHigh(_Symbol, R1,  R2);

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
      bool tgt_broke_low  = (tgt_w_low  < tgt_r_low);
      bool self_held_low  = (self_w_low >= self_r_low);
      bool tgt_broke_high = (tgt_w_high > tgt_r_high);
      bool self_held_high = (self_w_high <= self_r_high);

      if(tgt_broke_low && self_held_low)
      {
         int td = MathAbs(tgt_low_bar - self_low_bar);
         if     (td <= 1) score = 15;
         else if(td <= 2) score = 8;
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
   state.smt_confirmed = (score >= 8);
}

//+------------------------------------------------------------------+
void UpdateFatTailState(datetime ny)
{
   double raw   = 0.0;
   double range = iHigh(_Symbol, PERIOD_M5, 1) - iLow(_Symbol, PERIOD_M5, 1);
   if(range > ATR_Value) raw += W_FAT_RANGE;
   raw += TimingWeight(ny) * W_FAT_TIME;
   state.fat_tail_score  = NormalizeFatTail(raw);
   state.fat_tail_active = (state.fat_tail_score >= FAT_ACTIVE_THRESH);
}

//+------------------------------------------------------------------+
void UpdateNoTradeState(datetime ny)
{
   double score = 0.0;
   double range = iHigh(_Symbol, PERIOD_M5, 1) - iLow(_Symbol, PERIOD_M5, 1);
   if(range < ATR_Value * 0.5)   score += W_NOTRADE_RANGE;
   if(state.quality == CHOP)     score += W_NOTRADE_CHOP;
   if(!state.displacement_valid) score += W_NOTRADE_NODISP;
   if(!state.sweep_detected)     score += W_NOTRADE_NOSWEEP;
   if(!state.smt_confirmed)      score += W_NOTRADE_NOSMT;
   score += (1.0 - TimingWeight(ny)) * W_NOTRADE_WINDOW;
   state.no_trade_score = score;
   state.no_trade_day   = (score >= NOTRADE_THRESH);
}

//+------------------------------------------------------------------+
void CalculateScore(datetime ny)
{
   double raw = 0.0;
   if(state.sweep_detected)     raw += W_TOTAL_SWEEP;
   if(state.displacement_valid) raw += W_TOTAL_DISP;
   if(state.quality == CLEAN)   raw += W_TOTAL_QUAL;
   raw += TimingWeight(ny) * W_TOTAL_TIME;
   if(state.mitigation_valid)   raw += W_TOTAL_MITIG;
   raw += (state.smt_score / 15.0)       * W_TOTAL_SMT;
   raw += (state.fat_tail_score / 100.0) * W_TOTAL_FAT;
   state.total_score = NormalizeTotal(raw);
}

//+------------------------------------------------------------------+
void CalculatePressScore()
{
   double score = 0.0;
   score += (state.fat_tail_score / 100.0) * W_PRESS_FAT;
   score += (state.smt_score / 15.0)       * W_PRESS_SMT;
   if(state.quality == CLEAN)                       score += W_PRESS_QUAL;
   if(state.sweep_detected)                         score += W_PRESS_SWEEP;
   if(state.displacement_valid)                     score += W_PRESS_DISP;
   if(state.volume_confirmed && Use_Volume)         score += W_PRESS_VOL;
   if(state.no_trade_day)                           score -= PRESS_NO_TRADE_DED;
   state.press_score = ClampScore(score);
}

//+------------------------------------------------------------------+
void FinalDecision(datetime ny)
{
   state.decision        = "NO TRADE";
   state.direction       = DIR_NONE;
   state.risk_multiplier = 0.0;

   if(state.archetype == ARCH_BALANCE)
   {
      state.decision = "BALANCE DAY";
      return;
   }

   if(state.no_trade_day)
   {
      state.decision    = "BLOCKED";
      state.press_score = 0.0;
      return;
   }

   bool in_trade_window = (state.phase == EXPANSION) || (TimingWeight(ny) > 0.0);
   if(!in_trade_window) { state.decision = "WAIT EXPANSION"; return; }

   if(PastAssetCutoff(ny)) { state.decision = "CUTOFF"; return; }

   if(!state.hierarchy_approved) { state.decision = "OPPOSING INDEX"; return; }

   if(!state.sweep_detected)     { state.decision = "WAIT SWEEP";        return; }
   if(!state.displacement_valid) { state.decision = "WAIT DISPLACEMENT"; return; }

   if(state.total_score < TOTAL_TRADE_THRESH) { state.decision = "SKIP"; return; }

   state.direction = state.sweep_direction;

   if     (state.press_score >= 80.0) state.risk_multiplier = 1.5;
   else if(state.press_score >= 65.0) state.risk_multiplier = 1.25;
   else if(state.press_score >= 50.0) state.risk_multiplier = 1.0;
   else                               state.risk_multiplier = 0.5;

   if(state.archetype == ARCH_PROBE)
      state.risk_multiplier = MathMin(state.risk_multiplier, 1.0);

   if(state.mitigation_touch >= 2)
   {
      state.risk_multiplier = MathMin(state.risk_multiplier, 1.0);
      state.decision = "TRADE [2ND TOUCH]";
      return;
   }

   if(state.mitigation_valid && state.computed_rr > 0.0 && state.computed_rr < Min_RR_Trade)
   {
      state.decision        = "LOW RR";
      state.risk_multiplier = 0.0;
      state.direction       = DIR_NONE;
      return;
   }

   state.decision = "TRADE";

   if(state.press_score    >= PRESS_2R_THRESH  &&
      state.fat_tail_active                    &&
      state.smt_confirmed                      &&
      state.quality          == CLEAN          &&
      state.mitigation_valid                   &&
      state.mitigation_touch <= 1              &&
      state.computed_rr      >= Min_RR_Press   &&
      state.archetype        == ARCH_EXPANSION)
   {
      state.decision        = "PRESS 2R";
      state.risk_multiplier = 2.0;
   }
}

//+------------------------------------------------------------------+
string ArchetypeStr()
{
   switch(state.archetype)
   {
      case ARCH_EXPANSION: return "EXPANSION DAY";
      case ARCH_PROBE:     return "PROBE DAY";
      case ARCH_BALANCE:   return "BALANCE DAY";
      default:             return "UNKNOWN";
   }
}

//+------------------------------------------------------------------+
void RenderDashboard(datetime ny)
{
   string dir_str;
   switch(state.direction)
   {
      case DIR_BUY:  dir_str = "BUY";  break;
      case DIR_SELL: dir_str = "SELL"; break;
      default:       dir_str = "NONE"; break;
   }

   double tw = TimingWeight(ny);
   string window_str = (tw >= 0.99) ? "PRIME  [9:30-9:40]" :
                       (tw >= 0.50) ? "ACTIVE [9:40-9:47]" :
                       (tw >  0.0)  ? "DECAY  [9:47-9:55]" :
                                      "CLOSED";

   string sweep_detail = "";
   if(state.sweep_detected)
      sweep_detail = "  DIR: " + (state.sweep_direction == DIR_BUY ? "BUY" : "SELL")
                   + "  [" + IntegerToString(g_sweep_persist) + " bars]";

   string mitig_touch_str = (state.mitigation_touch == 0) ? "NONE" :
                            (state.mitigation_touch == 1) ? "1ST"  : "2ND+";

   string rr_str     = (state.computed_rr > 0.0)
                     ? DoubleToString(state.computed_rr, 2) + "R"
                     : "N/A";
   string target_str = (state.liquidity_target > 0.0)
                     ? DoubleToString(state.liquidity_target, _Digits)
                     : "N/A";

   string txt = "====== ELITE GRANDMASTER ENGINE v3.0 ======\n";
   txt += "TIME:      " + TimeToString(ny, TIME_MINUTES) + "\n";
   txt += "\nSESSION:   " + ArchetypeStr();
   txt += "\nPHASE:     " + EnumToString(state.phase);
   txt += "\nWINDOW:    " + window_str;
   txt += "\nQUALITY:   " + EnumToString(state.quality);
   txt += "\nHIERARCHY: " + (state.hierarchy_approved ? "ALIGNED" : "OPPOSING");
   txt += "\n";
   txt += "\nSWEEP:     " + (string)state.sweep_detected + sweep_detail;
   txt += "\nDISP:      " + (string)state.displacement_valid
        + "  [VOL: " + (state.volume_confirmed ? "SPIKE" : "NORMAL") + "]";
   txt += "\nMITIG:     " + (string)state.mitigation_valid
        + "  [" + mitig_touch_str + "]";
   txt += "\nLEG WIN:   persist=" + IntegerToString(g_sweep_persist_bars)
        + "  leg=" + IntegerToString(g_leg_bars);
   txt += "\n";
   txt += "\nTARGET:    " + target_str;
   txt += "\nRR:        " + rr_str;
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
