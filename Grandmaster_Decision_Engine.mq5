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

//================ STATE =================//
struct MasterState
{
   MARKET_PHASE     phase;
   MARKET_QUALITY   quality;

   bool             no_trade_day;
   int              no_trade_score;

   bool             sweep_detected;
   TRADE_DIRECTION  sweep_direction;

   bool             displacement_valid;
   bool             mitigation_valid;

   int              smt_score;
   bool             smt_confirmed;

   int              fat_tail_score;
   bool             fat_tail_active;

   int              total_score;
   int              press_score;

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

void DetectMitigation()
{
   // Mitigation proxy: last closed M5 bar (bar 1) closes inside the body of bar 2.
   // Bar 2 is the candidate order block — the candle preceding the displacement move.
   // If bar 2 is a doji (body < 10% ATR), widen the reference to its full range.
   double ob_open  = iOpen (_Symbol, PERIOD_M5, 2);
   double ob_close = iClose(_Symbol, PERIOD_M5, 2);
   double ob_hi    = MathMax(ob_open, ob_close);
   double ob_lo    = MathMin(ob_open, ob_close);

   if((ob_hi - ob_lo) < ATR_Value * 0.1)
   {
      ob_hi = iHigh(_Symbol, PERIOD_M5, 2);
      ob_lo = iLow (_Symbol, PERIOD_M5, 2);
   }

   double last_close       = iClose(_Symbol, PERIOD_M5, 1);
   state.mitigation_valid  = (last_close >= ob_lo && last_close <= ob_hi);
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
   if(!SymbolSelect(target, true)) return;

   double t_low  = iLow (target, PERIOD_D1, 1);
   double t_high = iHigh(target, PERIOD_D1, 1);
   double my_low = iLow (_Symbol, PERIOD_M5, 1);

   if(inverse)
   {
      // DXY breaking above yesterday's high while GOLD hasn't broken its low → divergence
      if(iHigh(target, PERIOD_M5, 1) > t_high && my_low > PDL)
         state.smt_score = 15;
   }
   else
   {
      // Correlated index making a new low below yesterday's low while current symbol holds → SMT
      if(iLow(target, PERIOD_M5, 1) < t_low && my_low > PDL)
         state.smt_score = 15;
   }

   state.smt_confirmed = (state.smt_score >= 10);
}

//================ FAT TAIL =================//
void UpdateFatTailState(datetime ny)
{
   int score = 0;

   // Closed M5 bar range
   double range = iHigh(_Symbol, PERIOD_M5, 1) - iLow(_Symbol, PERIOD_M5, 1);

   if(range > ATR_Value)        score += 10;
   if(state.displacement_valid) score += 10;
   if(state.quality == CLEAN)   score += 5;

   MqlDateTime t; TimeToStruct(ny, t);
   if(t.hour == 9 && t.min <= 40) score += 5;

   state.fat_tail_score  = score;
   state.fat_tail_active = (score >= 20);
}

//================ NO TRADE =================//
void UpdateNoTradeState(datetime ny)
{
   int score = 0;

   // Closed M5 bar range
   double range = iHigh(_Symbol, PERIOD_M5, 1) - iLow(_Symbol, PERIOD_M5, 1);

   if(range < ATR_Value * 0.5)    score += 25;
   if(state.quality == CHOP)      score += 20;
   if(!state.displacement_valid)  score += 15;
   if(!state.sweep_detected)      score += 15;
   if(!state.smt_confirmed)       score += 10;

   MqlDateTime t; TimeToStruct(ny, t);
   if(!(t.hour == 9 && t.min >= 30 && t.min <= 45)) score += 15;

   state.no_trade_score = score;
   state.no_trade_day   = (score >= 60);
}

//================ SCORING =================//
void CalculateScore(datetime ny)
{
   int total = 0;

   if(state.sweep_detected)      total += 20;
   if(state.displacement_valid)  total += 20;
   if(state.quality == CLEAN)    total += 10;

   MqlDateTime t; TimeToStruct(ny, t);
   if(t.hour == 9 && t.min >= 30 && t.min <= 45) total += 10;

   if(state.mitigation_valid)    total += 10;
   total += state.smt_score;
   total += (int)MathRound(state.fat_tail_score / 3.0);

   state.total_score = total;
}

//================ PRESS =================//
void CalculatePressScore(datetime ny)
{
   // Start from total_score — all components already encoded
   int score = state.total_score;

   // Press-specific bonuses use boolean flags, not raw sub-scores,
   // preventing double-counting of smt_score and fat_tail_score
   if(state.fat_tail_active) score += 15;
   if(state.smt_confirmed)   score += 10;
   if(state.quality == CLEAN) score += 10;
   if(state.no_trade_day)     score -= 20;

   state.press_score = score;
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

   if(state.total_score < 65)
   {
      state.decision = "SKIP";
      return;
   }

   // Direction derived from sweep type — single source of truth
   state.direction = state.sweep_direction;

   // Single authoritative risk assignment — not set anywhere else
   if     (state.press_score >= 80) state.risk_multiplier = 2.0;
   else if(state.press_score >= 65) state.risk_multiplier = 1.5;
   else if(state.press_score >= 50) state.risk_multiplier = 1.0;
   else                             state.risk_multiplier = 0.5;

   state.decision = "TRADE";

   if(state.press_score >= 80 &&
      state.fat_tail_active   &&
      state.smt_confirmed     &&
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
   txt += "\nFAT: "      + IntegerToString(state.fat_tail_score);
   txt += "\n\nTOTAL: "   + IntegerToString(state.total_score);
   txt += "\nNO TRADE: " + IntegerToString(state.no_trade_score);
   txt += "\nPRESS: "    + IntegerToString(state.press_score);
   txt += "\n\nDECISION: "  + state.decision;
   txt += "\nDIRECTION: "   + dir_str;
   txt += "\nRISK: "        + DoubleToString(state.risk_multiplier, 1);

   Comment(txt);
}
