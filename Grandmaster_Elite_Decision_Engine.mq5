//+------------------------------------------------------------------+
//| GRANDMASTER ELITE DECISION ENGINE v6.8 - FINAL PRODUCTION GRADE  |
//| Integrated with robust time, SMT, scoring, and risk management   |
//+------------------------------------------------------------------+
#property indicator_chart_window
#property indicator_plots 0
#property indicator_buffers 0
#property indicator_minimum 0
#property indicator_maximum 100

//================ INPUTS =================//
input ENUM_TIMEFRAMES TF = PERIOD_M5; // Timeframe for analysis
input int ATR_Period = 14;            // ATR Period
input int SMT_Lookback_Window = 3;    // Bars for SMT window-based detection
input int ADX_Period = 14;            // ADX Period for Market Quality
input int RSI_Period = 14;            // RSI Period for SMT confirmation

input string NAS100 = "NAS100";       // Correlated symbol for SMT
input string US30   = "US30";         // Correlated symbol for SMT
input string GOLD   = "XAUUSD";       // Correlated symbol for SMT
input string DXY    = "USDX";         // Correlated symbol for SMT

input int UTC_OFFSET_BROKER = 0;      // Broker's UTC offset (e.g., 2 for GMT+2)

// Risk Management Inputs
input double Base_Risk_Percent = 0.5;     // Base risk per trade (e.g., 0.5% of account equity)
input double Max_Risk_Percent = 1.5;      // Maximum allowable risk per trade (e.g., 1.5% of account equity)
input double Min_Conviction_Threshold = 50.0; // Minimum conviction score to consider a trade
input double Max_Conviction_Threshold = 100.0; // Max conviction score for max risk

input double Max_Drawdown_Threshold = 5.0; // e.g., 5% drawdown from peak equity to reduce risk
input double Risk_Reduction_Factor = 0.5;  // e.g., reduce risk by 50% during drawdown
input double Min_Effective_Risk_Percent = 0.1; // Minimum effective risk even during deep drawdown

input double Max_Daily_Loss_Percent = 3.0; // e.g., 3% daily loss limit to stop trading
input double Max_Weekly_Loss_Percent = 7.0; // e.g., 7% weekly loss limit to stop trading

// Dynamic Dead Market Thresholds
input double Dead_Market_ATR_Factor = 0.3; // Factor of long-term ATR for dead market detection
input double Dead_Market_Volume_Factor = 0.3; // Factor of long-term average volume for dead market detection
input int Long_Term_Period_D1 = 20; // Period for calculating long-term ATR/Volume (e.g., 20 days)

//================ ENUMS =================//
enum MARKET_PHASE { ACCUMULATION, MANIPULATION, EXPANSION, UNKNOWN, DEAD_MARKET };
enum MARKET_QUALITY { CLEAN, MIXED, CHOP };
enum TRADE_DIRECTION { NONE, BUY, SELL };

//================ STATE =================//
struct State
{
   MARKET_PHASE phase;
   MARKET_QUALITY quality;

   bool sweep;
   bool displacement;

   bool smt;
   int smt_score;

   bool fat_tail;
   int fat_score;

   bool no_trade;
   int no_trade_score;

   double target_price;
   string target_name;

   double trade_conviction_score; // NEW: Comprehensive, normalized score

   double risk; // Final calculated risk as a percentage of equity
   string decision;
   TRADE_DIRECTION direction;
};

State s;

//================ GLOBALS =================//
int ATR_Handle;
double ATR_Buffer[];
double ATR;

int ADX_Handle;
double ADX_Main_Buffer[];
double ADX_PlusDI_Buffer[];
double ADX_MinusDI_Buffer[];

int RSI_Handle_My;
double RSI_My_Buffer[];
int RSI_Handle_Target = INVALID_HANDLE;
double RSI_Target_Buffer[];

int Volume_Handle_My;
long Volume_My_Buffer[];
int Volume_Handle_Target = INVALID_HANDLE;
long Volume_Target_Buffer[];

double PDH, PDL, PWH, PWL; // Previous Day/Week High/Low

datetime last_bar = 0;

// Risk Management Globals
double Initial_Account_Balance = 0.0;
double Max_Account_Balance = 0.0;
double Current_Drawdown_Percent = 0.0;
double Daily_Start_Balance = 0.0;
double Weekly_Start_Balance = 0.0;
datetime Last_Day_Reset = 0;
datetime Last_Week_Reset = 0;

//================ FORWARD DECLARATIONS =================//
datetime GetNYTime(datetime t);
void UpdateATR();
void UpdatePhase(datetime ny);
void UpdateQuality();
void UpdateLevels();
void DetectSweep(double h_prev, double l_prev, double c_prev);
void DetectDisplacement(double o_prev, double c_prev);
void UpdateSMT_Robust();
void UpdateFatTail(datetime ny, double h_prev, double l_prev, double o_prev, double c_prev);
void UpdateNoTrade();
void DetermineLiquidityTarget();
void CalculateTradeConviction();
void FinalDecision();
void Render(datetime ny);
void CheckLossLimits();
void UpdateDrawdownAndRisk();

//================ INIT =================//
int OnInit()
{
   // ATR Initialization
   ATR_Handle = iATR(_Symbol, TF, ATR_Period);
   ArraySetAsSeries(ATR_Buffer, true);
   if(ATR_Handle == INVALID_HANDLE)
   {
      Print("ATR INIT FAILED");
      return INIT_FAILED;
   }

   // ADX Initialization
   ADX_Handle = iADX(_Symbol, TF, ADX_Period);
   ArraySetAsSeries(ADX_Main_Buffer, true);
   ArraySetAsSeries(ADX_PlusDI_Buffer, true);
   ArraySetAsSeries(ADX_MinusDI_Buffer, true);
   if(ADX_Handle == INVALID_HANDLE)
   {
      Print("ADX INIT FAILED");
      return INIT_FAILED;
   }

   // RSI Initialization (for SMT confirmation)
   RSI_Handle_My = iRSI(_Symbol, TF, RSI_Period, PRICE_CLOSE);
   ArraySetAsSeries(RSI_My_Buffer, true);
   if(RSI_Handle_My == INVALID_HANDLE)
   {
      Print("RSI My INIT FAILED");
      return INIT_FAILED;
   }

   // Volume Initialization (for SMT confirmation)
   Volume_Handle_My = iBars(_Symbol, TF);
   ArraySetAsSeries(Volume_My_Buffer, true);

   // Initialize indicator handles for the target symbol for SMT
   string smt_target_symbol = "";
   if (_Symbol == NAS100) smt_target_symbol = US30;
   else if (_Symbol == US30) smt_target_symbol = NAS100;
   else if (_Symbol == GOLD) smt_target_symbol = DXY;

   if (smt_target_symbol != "")
   {
       RSI_Handle_Target = iRSI(smt_target_symbol, TF, RSI_Period, PRICE_CLOSE);
       ArraySetAsSeries(RSI_Target_Buffer, true);

       Volume_Handle_Target = iBars(smt_target_symbol, TF);
       ArraySetAsSeries(Volume_Target_Buffer, true);
   }

   // Risk Management Initialization
   Initial_Account_Balance = AccountInfoDouble(ACCOUNT_BALANCE);
   Max_Account_Balance = Initial_Account_Balance;
   Daily_Start_Balance = Initial_Account_Balance;
   Weekly_Start_Balance = Initial_Account_Balance;
   Last_Day_Reset = TimeCurrent();
   Last_Week_Reset = TimeCurrent();

   return INIT_SUCCEEDED;
}

//================ ON CALCULATE =================//
int OnCalculate(const int rates_total,const int prev_calculated,
                const datetime &time[],const double &open[],
                const double &high[],const double &low[],
                const double &close[],const long &tick_volume[],
                const long &volume[],const int &spread[])
{
   // Ensure enough bars for calculations
   if(rates_total < MathMax(ATR_Period, MathMax(ADX_Period, RSI_Period)) + SMT_Lookback_Window + 2) return 0;

   // Process only on new bar
   if(time[rates_total-1] == last_bar) return rates_total;
   last_bar = time[rates_total-1];

   // Reset state for new bar
   ZeroMemory(s);
   s.direction = NONE;
   s.decision = "NO TRADE";

   // Check and enforce loss limits first
   CheckLossLimits();
   if (s.no_trade) // If loss limit reached, block further processing
   {
       Comment(s.decision + "\n" + "Current Drawdown: " + DoubleToString(Current_Drawdown_Percent, 2) + "%");
       return rates_total;
   }

   datetime ny = GetNYTime(TimeCurrent());

   // ENVIRONMENT
   UpdateATR();
   UpdatePhase(ny);
   UpdateQuality();
   UpdateLevels();

   // STRUCTURE
   // All price data should be from the *closed* bar (index 1)
   DetectSweep(high[rates_total-2], low[rates_total-2], close[rates_total-2]);
   DetectDisplacement(open[rates_total-2], close[rates_total-2]);

   // CONFIRMATION
   UpdateSMT_Robust();
   UpdateFatTail(ny, high[rates_total-2], low[rates_total-2], open[rates_total-2], close[rates_total-2]);
   UpdateNoTrade();

   // TARGET
   DetermineLiquidityTarget();

   // SCORING & PROBABILITY (Combined into one comprehensive score)
   CalculateTradeConviction();

   // DECISION
   FinalDecision();

   // OUTPUT
   Render(ny);

   return rates_total;
}

//================ TIME =================//
datetime GetNYTime(datetime t)
{
   datetime utc = t - (UTC_OFFSET_BROKER * 3600);
   MqlDateTime dt_utc;
   TimeToStruct(utc, dt_utc);

   int ny_offset_hours = 5; // Default to EST (UTC-5)

   bool is_dst = false;
   // DST starts second Sunday in March, ends first Sunday in November
   if (dt_utc.mon > 3 && dt_utc.mon < 11)
   {
      is_dst = true;
   }
   else if (dt_utc.mon == 3)
   {
      MqlDateTime first_day_of_march;
      ZeroMemory(first_day_of_march);
      first_day_of_march.year = dt_utc.year;
      first_day_of_march.mon = 3;
      first_day_of_march.day = 1;

      datetime first_march_dt = StructToTime(first_day_of_march);
      MqlDateTime dt_first_march;
      TimeToStruct(first_march_dt, dt_first_march);
      int day_of_week_first_march = dt_first_march.day_of_week;
      int second_sunday_day = 1 + (7 - day_of_week_first_march) % 7 + 7;
      if (dt_utc.day >= second_sunday_day)
      {
         is_dst = true;
      }
   }
   else if (dt_utc.mon == 11)
   {
      MqlDateTime first_day_of_november;
      ZeroMemory(first_day_of_november);
      first_day_of_november.year = dt_utc.year;
      first_day_of_november.mon = 11;
      first_day_of_november.day = 1;

      datetime first_november_dt = StructToTime(first_day_of_november);
      MqlDateTime dt_first_november;
      TimeToStruct(first_november_dt, dt_first_november);
      int day_of_week_first_november = dt_first_november.day_of_week;
      int first_sunday_day = 1 + (7 - day_of_week_first_november) % 7;
      if (dt_utc.day < first_sunday_day)
      {
         is_dst = true;
      }
   }

   if (is_dst)
   {
      ny_offset_hours = 4; // EDT (UTC-4)
   }

   return utc - ny_offset_hours * 3600;
}

//================ ATR =================//
void UpdateATR()
{
   if(CopyBuffer(ATR_Handle,0,1,1,ATR_Buffer)>0)
      ATR = ATR_Buffer[0];
   else
      ATR = 0;
}

//================ MARKET =================//
void UpdatePhase(datetime ny)
{
   MqlDateTime t; TimeToStruct(ny,t);

   double current_atr = ATR;
   long current_volume = 0;
   long vol_buf[1];
   if(CopyTickVolume(_Symbol, TF, 1, 1, vol_buf) > 0)
   {
      current_volume = vol_buf[0];
   }

   double avg_atr_long_term = 0;
   double atr_d1_buf[1];
   int handle_d1 = iATR(_Symbol, PERIOD_D1, Long_Term_Period_D1);
   if(handle_d1 != INVALID_HANDLE)
   {
      if(CopyBuffer(handle_d1, 0, 1, 1, atr_d1_buf) > 0) avg_atr_long_term = atr_d1_buf[0];
      IndicatorRelease(handle_d1);
   }

   double avg_volume_long_term = 0;
   long vol_d1_buf[1];
   if(CopyTickVolume(_Symbol, PERIOD_D1, 1, 1, vol_d1_buf) > 0) avg_volume_long_term = (double)vol_d1_buf[0];

   double dynamic_low_atr_threshold = Dead_Market_ATR_Factor * avg_atr_long_term;
   double dynamic_low_volume_threshold = Dead_Market_Volume_Factor * avg_volume_long_term;

   if (current_atr < dynamic_low_atr_threshold && (double)current_volume < dynamic_low_volume_threshold)
   {
       s.phase = DEAD_MARKET;
   }
   else if(t.hour < 7) s.phase = ACCUMULATION;
   else if(t.hour < 9) s.phase = MANIPULATION;
   else if(t.hour <= 11) s.phase = EXPANSION;
   else s.phase = UNKNOWN;
}

void UpdateQuality()
{
   double adx_main_val[1];
   if(CopyBuffer(ADX_Handle, 0, 1, 1, adx_main_val) > 0)
   {
      double adx_value = adx_main_val[0];
      if (adx_value > 25) s.quality = CLEAN;
      else if (adx_value >= 20) s.quality = MIXED;
      else s.quality = CHOP;
   }
   else s.quality = CHOP;
}

//================ LEVELS =================//
void UpdateLevels()
{
   PDH = iHigh(_Symbol, PERIOD_D1, 1);
   PDL = iLow(_Symbol, PERIOD_D1, 1);
   PWH = iHigh(_Symbol, PERIOD_W1, 1);
   PWL = iLow(_Symbol, PERIOD_W1, 1);
}

//================ STRUCTURE =================//
void DetectSweep(double h_prev, double l_prev, double c_prev)
{
   s.sweep = false;
   s.direction = NONE;
   if (h_prev > PDH && c_prev < PDH){ s.sweep = true; s.direction = SELL; }
   else if (l_prev < PDL && c_prev > PDL){ s.sweep = true; s.direction = BUY; }
   else if (h_prev > PWH && c_prev < PWH){ s.sweep = true; s.direction = SELL; }
   else if (l_prev < PWL && c_prev > PWL){ s.sweep = true; s.direction = BUY; }
}

void DetectDisplacement(double o_prev, double c_prev)
{
   double body = MathAbs(c_prev - o_prev);
   s.displacement = (body > ATR * 0.5);
}

//================ SMT =================//
void CheckHigherTimeframeSMT(string symbol1, string symbol2, ENUM_TIMEFRAMES ht_tf, int& smt_score_ref)
{
   if (!SymbolSelect(symbol1, true) || !SymbolSelect(symbol2, true)) return;
   double s1_ht_low = iLow(symbol1, ht_tf, 1);
   double s1_ht_high = iHigh(symbol1, ht_tf, 1);
   double s1_ht_pdl = iLow(symbol1, PERIOD_D1, 1);
   double s1_ht_pdh = iHigh(symbol1, PERIOD_D1, 1);
   double s2_ht_low = iLow(symbol2, ht_tf, 1);
   double s2_ht_high = iHigh(symbol2, ht_tf, 1);
   double s2_ht_pdl = iLow(symbol2, PERIOD_D1, 1);
   double s2_ht_pdh = iHigh(symbol2, PERIOD_D1, 1);
   bool ht_bullish_smt = ((s1_ht_low < s1_ht_pdl && s2_ht_low > s2_ht_pdl) || (s2_ht_low < s2_ht_pdl && s1_ht_low > s1_ht_pdl));
   bool ht_bearish_smt = ((s1_ht_high > s1_ht_pdh && s2_ht_high < s2_ht_pdh) || (s2_ht_high > s2_ht_pdh && s1_ht_high < s1_ht_pdh));
   if ((ht_bullish_smt && s.direction == BUY) || (ht_bearish_smt && s.direction == SELL)) smt_score_ref += 20;
}

void UpdateSMT_Robust()
{
   s.smt = false; s.smt_score = 0;
   string target_symbol = "";
   if (_Symbol == NAS100) target_symbol = US30;
   else if (_Symbol == US30) target_symbol = NAS100;
   else if (_Symbol == GOLD) target_symbol = DXY;
   if (target_symbol == "" || !SymbolSelect(target_symbol, true)) return;
   MqlRates rates_my[2], rates_target[2];
   if (CopyRates(_Symbol, TF, 0, 2, rates_my) != 2 || CopyRates(target_symbol, TF, 0, 2, rates_target) != 2) return;
   if (rates_my[1].time != rates_target[1].time) return;
   double my_pdl = iLow(_Symbol, PERIOD_D1, 1);
   double my_pdh = iHigh(_Symbol, PERIOD_D1, 1);
   double target_pdl = iLow(target_symbol, PERIOD_D1, 1);
   double target_pdh = iHigh(target_symbol, PERIOD_D1, 1);
   double my_lowest_low_window = iLow(_Symbol, TF, iLowest(_Symbol, TF, MODE_LOW, SMT_Lookback_Window, 1));
   double my_highest_high_window = iHigh(_Symbol, TF, iHighest(_Symbol, TF, MODE_HIGH, SMT_Lookback_Window, 1));
   double target_lowest_low_window = iLow(target_symbol, TF, iLowest(target_symbol, TF, MODE_LOW, SMT_Lookback_Window, 1));
   double target_highest_high_window = iHigh(target_symbol, TF, iHighest(target_symbol, TF, MODE_HIGH, SMT_Lookback_Window, 1));
   bool bullish_smt = ((my_lowest_low_window < my_pdl && target_lowest_low_window > target_pdl) || (target_lowest_low_window < target_pdl && my_lowest_low_window > my_pdl));
   bool bearish_smt = ((my_highest_high_window > my_pdh && target_highest_high_window < target_pdh) || (target_highest_high_window > target_pdh && my_highest_high_window < my_pdh));
   if (bullish_smt || bearish_smt)
   {
       s.smt = true;
       s.direction = (TRADE_DIRECTION)(bullish_smt ? BUY : SELL);
       int base_score = 15;
       double target_atr = 0;
       double atr_target_buf[1];
       int h_atr_target = iATR(target_symbol, TF, ATR_Period);
       if(h_atr_target != INVALID_HANDLE) { if(CopyBuffer(h_atr_target, 0, 1, 1, atr_target_buf) > 0) target_atr = atr_target_buf[0]; IndicatorRelease(h_atr_target); }
       if (bullish_smt && (my_lowest_low_window > my_pdl + (ATR * 0.5) || target_lowest_low_window > target_pdl + (target_atr * 0.5))) base_score += 10;
       if (bearish_smt && (my_highest_high_window < my_pdh - (ATR * 0.5) || target_highest_high_window < target_pdh - (target_atr * 0.5))) base_score += 10;
       CheckHigherTimeframeSMT(_Symbol, target_symbol, PERIOD_H1, base_score);
       double rsi_my_val[2], rsi_target_val[2];
       long vol_my_val[2], vol_target_val[2];
       if (CopyBuffer(RSI_Handle_My, 0, 1, 2, rsi_my_val) == 2 && CopyBuffer(RSI_Handle_Target, 0, 1, 2, rsi_target_val) == 2 &&
           CopyTickVolume(_Symbol, TF, 1, 2, vol_my_val) == 2 && CopyTickVolume(target_symbol, TF, 1, 2, vol_target_val) == 2)
       {
           if (bullish_smt && rates_my[1].low < rates_my[0].low && rsi_my_val[0] > rsi_my_val[1]) base_score += 10;
           if (bearish_smt && rates_my[1].high > rates_my[0].high && rsi_my_val[0] < rsi_my_val[1]) base_score += 10;
           if (bullish_smt && rates_my[1].low < rates_my[0].low && vol_my_val[0] < vol_my_val[1]) base_score += 5;
           if (bearish_smt && rates_my[1].high > rates_my[0].high && vol_my_val[0] > vol_my_val[1]) base_score += 5;
       }
       s.smt_score = base_score;
   }
}

//================ FAT TAIL =================//
void UpdateFatTail(datetime ny, double h_prev, double l_prev, double o_prev, double c_prev)
{
   int score = 0;
   double range = h_prev - l_prev;
   double body = MathAbs(c_prev - o_prev);
   double wick_ratio = (range > 0) ? (range - body) / range : 0.0;
   if (range > ATR * 1.0) score += 5;
   if (wick_ratio > 0.5) score += 10;
   if (s.quality == CLEAN) score += 5;
   s.fat_score = score; s.fat_tail = (score >= 15);
}

//================ NO TRADE =================//
void UpdateNoTrade()
{
   int score=0;
   if(s.quality==CHOP) score+=20;
   if(!s.displacement) score+=15;
   if(!s.sweep) score+=15;
   if(!s.smt) score+=10;
   if(s.phase==DEAD_MARKET) score+=30;
   s.no_trade_score=score; s.no_trade=(score>=60);
}

//================ LIQUIDITY =================//
void DetermineLiquidityTarget()
{
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   s.target_price = 0; s.target_name = "NONE";
   if (s.direction == BUY)
   {
      if (PDH > price && PWH > price) { if (PDH < PWH) { s.target_price = PDH; s.target_name = "PDH"; } else { s.target_price = PWH; s.target_name = "PWH"; } }
      else if (PDH > price) { s.target_price = PDH; s.target_name = "PDH"; }
      else if (PWH > price) { s.target_price = PWH; s.target_name = "PWH"; }
   }
   else if (s.direction == SELL)
   {
      if (PDL < price && PWL < price) { if (PDL > PWL) { s.target_price = PDL; s.target_name = "PDL"; } else { s.target_price = PWL; s.target_name = "PWL"; } }
      else if (PDL < price) { s.target_price = PDL; s.target_name = "PDL"; }
      else if (PWL < price) { s.target_price = PWL; s.target_name = "PWL"; }
   }
}

//================ CONVICTION SCORING =================//
#define MAX_CONVICTION_SCORE 130.0
void CalculateTradeConviction()
{
   double raw_score = 0.0;
   if (s.sweep) raw_score += 25.0;
   if (s.displacement) raw_score += 20.0;
   if (s.quality == CLEAN) raw_score += 15.0;
   else if (s.quality == MIXED) raw_score += 5.0;
   if (s.phase == EXPANSION) raw_score += 10.0;
   else if (s.phase == MANIPULATION) raw_score += 5.0;
   raw_score += s.smt_score;
   if (s.fat_tail && !s.displacement) raw_score += 10.0;
   else if (s.fat_tail && s.displacement) raw_score += 5.0;
   double price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double distance_to_target = MathAbs(s.target_price - price);
   if (s.direction != NONE && s.target_price != 0)
   {
      if (distance_to_target < ATR * 1.0) raw_score += 15.0;
      else if (distance_to_target < ATR * 2.0) raw_score += 10.0;
      else if (distance_to_target < ATR * 3.0) raw_score += 5.0;
   }
   if (s.smt && s.quality == CHOP) raw_score -= 10.0;
   if (s.displacement && s.phase == EXPANSION) raw_score += 5.0;
   if (s.direction != NONE && s.target_price != 0 && distance_to_target < SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 10) raw_score -= 5.0;
   if (raw_score < 0) raw_score = 0;
   s.trade_conviction_score = (raw_score / MAX_CONVICTION_SCORE) * 100.0;
   if (s.trade_conviction_score > 100.0) s.trade_conviction_score = 100.0;
}

//================ FINAL DECISION & RISK =================//
void UpdateDrawdownAndRisk()
{
   double current_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if (current_balance > Max_Account_Balance) Max_Account_Balance = current_balance;
   if (Max_Account_Balance > 0) Current_Drawdown_Percent = ((Max_Account_Balance - current_balance) / Max_Account_Balance) * 100.0;
   else Current_Drawdown_Percent = 0.0;
}

void CheckLossLimits()
{
   datetime current_time = TimeCurrent();
   MqlDateTime dt_current, dt_last_day_reset, dt_last_week_reset;
   TimeToStruct(current_time, dt_current);
   TimeToStruct(Last_Day_Reset, dt_last_day_reset);
   TimeToStruct(Last_Week_Reset, dt_last_week_reset);
   if (dt_current.day != dt_last_day_reset.day || dt_current.mon != dt_last_day_reset.mon || dt_current.year != dt_last_day_reset.year)
   { Daily_Start_Balance = AccountInfoDouble(ACCOUNT_BALANCE); Last_Day_Reset = current_time; }
   if (dt_current.day_of_week == 1 && dt_last_week_reset.day_of_week != 1)
   { Weekly_Start_Balance = AccountInfoDouble(ACCOUNT_BALANCE); Last_Week_Reset = current_time; }
   double current_balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if (Daily_Start_Balance > 0 && ((Daily_Start_Balance - current_balance) / Daily_Start_Balance) * 100.0 >= Max_Daily_Loss_Percent)
   { s.no_trade = true; s.decision = "DAILY LOSS LIMIT REACHED"; return; }
   if (Weekly_Start_Balance > 0 && ((Weekly_Start_Balance - current_balance) / Weekly_Start_Balance) * 100.0 >= Max_Weekly_Loss_Percent)
   { s.no_trade = true; s.decision = "WEEKLY LOSS LIMIT REACHED"; return; }
}

void FinalDecision()
{
   s.decision = "NO TRADE"; s.risk = 0.0;
   if (s.no_trade) { s.decision = "BLOCKED"; return; }
   if (s.quality == CHOP) { s.decision = "BLOCKED - CHOP"; return; }
   if (s.phase == DEAD_MARKET) { s.decision = "BLOCKED - DEAD MARKET"; return; }
   UpdateDrawdownAndRisk();
   double effective_base_risk = Base_Risk_Percent;
   double effective_max_risk = Max_Risk_Percent;
   if (Current_Drawdown_Percent >= Max_Drawdown_Threshold)
   {
      effective_base_risk *= Risk_Reduction_Factor; effective_max_risk *= Risk_Reduction_Factor;
      effective_base_risk = MathMax(effective_base_risk, Min_Effective_Risk_Percent);
      effective_max_risk = MathMax(effective_max_risk, Min_Effective_Risk_Percent * 2);
   }
   bool is_trend_trade_candidate = (s.phase == EXPANSION && s.quality == CLEAN && s.trade_conviction_score >= Min_Conviction_Threshold);
   if (!s.sweep && !is_trend_trade_candidate) { s.decision = "WAIT SWEEP"; return; }
   if (!s.displacement && !is_trend_trade_candidate) { s.decision = "WAIT DISP"; return; }
   if (s.trade_conviction_score < Min_Conviction_Threshold) { s.decision = "SKIP LOW CONV"; return; }
   double normalized_conviction_range = Max_Conviction_Threshold - Min_Conviction_Threshold;
   double conviction_factor = (s.trade_conviction_score - Min_Conviction_Threshold) / normalized_conviction_range;
   conviction_factor = MathMax(0.0, MathMin(1.0, conviction_factor));
   double calculated_risk_percent = effective_base_risk + (conviction_factor * (effective_max_risk - effective_base_risk));
   s.risk = calculated_risk_percent;
   if (calculated_risk_percent >= (effective_max_risk * 0.9)) s.decision = "PRESS";
   else if (calculated_risk_percent >= (effective_max_risk * 0.6)) s.decision = "TRADE HIGH CONV";
   else if (calculated_risk_percent >= (effective_max_risk * 0.3)) s.decision = "TRADE";
   else s.decision = "TRADE LOW CONV";
   if (is_trend_trade_candidate && !s.sweep) s.decision = "TREND CONT";
}

//================ UI =================//
void Render(datetime ny)
{
   string txt = "===== GM ELITE v6.8 FINAL PRODUCTION =====\n";
   txt+="TIME: "+TimeToString(ny,TIME_MINUTES)+"\n\n";
   txt+="PHASE: "+EnumToString(s.phase)+"\n";
   txt+="QUALITY: "+EnumToString(s.quality)+"\n\n";
   txt+="DIR: "+EnumToString(s.direction)+"\n";
   txt+="SWEEP: "+(string)s.sweep+"\n";
   txt+="DISP: "+(string)s.displacement+"\n\n";
   txt+="TARGET: "+s.target_name+"\n";
   txt+="CONVICTION: "+DoubleToString(s.trade_conviction_score, 2)+"\n\n";
   txt+="DECISION: "+s.decision+"\n";
   txt+="RISK: "+DoubleToString(s.risk,2)+"%\n";
   txt+="DRAWDOWN: "+DoubleToString(Current_Drawdown_Percent, 2)+"%\n";
   Comment(txt);
}
