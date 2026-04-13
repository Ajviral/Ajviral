//+------------------------------------------------------------------+
//| Elite Grandmaster Guard EA v3.2 — Minimalist One-Shot Enforcer  |
//| Rules: Kill Zone Entry Gate | One-Shot-Per-Day | 16:30 Force Close|
//| Zero escalation. Zero violation counting. Zero cooldown/blocking.|
//+------------------------------------------------------------------+
#property copyright "Elite Grandmaster Guard v3.2"
#property version   "3.20"
#property strict

#include <Trade\Trade.mqh>

//--- Input parameters
input group "=== Kill Zone (NY Time) ==="
input int    KZ_Start_Hour   = 9;     // Kill Zone start hour (NY)
input int    KZ_Start_Min    = 30;    // Kill Zone start minute
input int    KZ_End_Hour     = 10;    // Kill Zone end hour (NY)
input int    KZ_End_Min      = 59;    // Kill Zone end minute
input int    FC_Hour         = 16;    // Force close hour (NY)
input int    FC_Min          = 30;    // Force close minute

input group "=== Chart Display ==="
input color  Color_PreKZ     = clrBlack;   // Pre-kill zone background
input color  Color_KZ        = clrGreen;   // Inside kill zone background
input color  Color_Locked    = clrGreen;   // Trade running background
input color  Color_ForceZone = clrRed;     // Force close zone background

input group "=== Notifications ==="
input bool   Enable_Alerts   = true;   // Enable on-screen alerts
input bool   Enable_Push     = true;   // Enable push notifications

input group "=== DST Reminder ==="
input int    DST_Remind_Days = 4;      // Days before DST transition to warn

//+------------------------------------------------------------------+
//| GlobalVariable keys — 3 only, symbol-prefixed                   |
//+------------------------------------------------------------------+
string GV_TRADE_DAY;   // Day on which a trade was taken
string GV_RESET_DAY;   // Day on which DailyReset last fired
string GV_FC_DONE;     // Force close completed today flag

//--- State enum — 4 states, no ST_BLOCKED
enum EState { ST_PRE_KZ = 0, ST_KZ_ACTIVE = 1, ST_LOCKED = 2, ST_FORCE_ZONE = 3 };

//--- Core globals — minimal set
datetime g_trade_day        = 0;
bool     g_trade_taken      = false;
bool     g_fc_done_today    = false;
datetime g_fc_first_attempt = 0;
datetime g_last_reset_day   = 0;
bool     g_kz_was_active    = false;
EState   g_state            = ST_PRE_KZ;

//--- DST reminder flags
bool     g_dst_spring       = false;
bool     g_dst_fall         = false;
int      g_dst_year         = 0;

//--- Trade object
CTrade trade;

//+------------------------------------------------------------------+
//| MakeTime: Field-by-field struct init (MQL5 has no C99 literals)  |
//+------------------------------------------------------------------+
datetime MakeTime(int yr, int mo, int dy, int hr = 0, int mn = 0)
{
   MqlDateTime d;
   ZeroMemory(d);
   d.year = yr; d.mon = mo; d.day = dy;
   d.hour = hr; d.min = mn; d.sec = 0;
   return StructToTime(d);
}

//+------------------------------------------------------------------+
//| IsDST: Returns true if NY is on EDT (UTC-4) vs EST (UTC-5)       |
//| Spring forward: 2nd Sunday March  — at 07:00 UTC                 |
//| Fall back:      1st Sunday November — at 06:00 UTC               |
//+------------------------------------------------------------------+
bool IsDST(datetime gmt)
{
   MqlDateTime t;
   TimeToStruct(gmt, t);
   int y = t.year;

   // Second Sunday in March
   datetime march1 = MakeTime(y, 3, 1);
   MqlDateTime m1; TimeToStruct(march1, m1);
   int dow = m1.day_of_week;                       // 0 = Sunday
   int first_sun_march  = (dow == 0) ? 1 : 1 + (7 - dow);
   int second_sun_march = first_sun_march + 7;
   datetime spring = MakeTime(y, 3, second_sun_march, 7); // 07:00 UTC

   // First Sunday in November
   datetime nov1 = MakeTime(y, 11, 1);
   MqlDateTime n1; TimeToStruct(nov1, n1);
   dow = n1.day_of_week;
   int first_sun_nov = (dow == 0) ? 1 : 1 + (7 - dow);
   datetime fall = MakeTime(y, 11, first_sun_nov, 6);     // 06:00 UTC

   return (gmt >= spring && gmt < fall);
}

//+------------------------------------------------------------------+
//| NyTime: Returns current NY datetime from GMT                     |
//+------------------------------------------------------------------+
datetime NyTime()
{
   datetime gmt = TimeGMT();
   int offset = IsDST(gmt) ? (-4 * 3600) : (-5 * 3600);
   return gmt + offset;
}

//+------------------------------------------------------------------+
//| TodayNY: Returns midnight of the current NY calendar day         |
//+------------------------------------------------------------------+
datetime TodayNY()
{
   MqlDateTime d;
   TimeToStruct(NyTime(), d);
   return MakeTime(d.year, d.mon, d.day);
}

//+------------------------------------------------------------------+
//| InKillZone: True if ny is within 9:30–10:59 AM NY               |
//+------------------------------------------------------------------+
bool InKillZone(datetime ny)
{
   MqlDateTime d;
   TimeToStruct(ny, d);
   int mins    = d.hour * 60 + d.min;
   int kz_start = KZ_Start_Hour * 60 + KZ_Start_Min;
   int kz_end   = KZ_End_Hour   * 60 + KZ_End_Min;
   return (mins >= kz_start && mins <= kz_end);
}

//+------------------------------------------------------------------+
//| AfterFC: True if ny is at or past 16:30 NY                      |
//+------------------------------------------------------------------+
bool AfterFC(datetime ny)
{
   MqlDateTime d;
   TimeToStruct(ny, d);
   int mins = d.hour * 60 + d.min;
   return (mins >= FC_Hour * 60 + FC_Min);
}

//+------------------------------------------------------------------+
//| IsWeekend: True on Saturday (6) or Sunday (0) in NY time        |
//+------------------------------------------------------------------+
bool IsWeekend(datetime ny)
{
   MqlDateTime d;
   TimeToStruct(ny, d);
   return (d.day_of_week == 0 || d.day_of_week == 6);
}

//+------------------------------------------------------------------+
//| Log: Structured log with NY timestamp                            |
//+------------------------------------------------------------------+
void Log(string event, string detail = "")
{
   string msg = "[GMG] " + TimeToString(NyTime(), TIME_DATE | TIME_MINUTES)
              + " | " + event;
   if(detail != "") msg += " | " + detail;
   Print(msg);
}

//+------------------------------------------------------------------+
//| CloseAll: Close all positions on this symbol                     |
//| No Sleep(), no retry loops — single attempt per call            |
//+------------------------------------------------------------------+
void CloseAll(string reason)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(PositionGetString(POSITION_SYMBOL) != Symbol()) continue;
      if(trade.PositionClose(ticket))
         Log("CLOSE_OK", "Ticket=" + IntegerToString(ticket) + " Reason=" + reason);
      else
         Log("CLOSE_FAIL", "Ticket=" + IntegerToString(ticket)
             + " Error=" + IntegerToString(GetLastError()));
   }
}

//+------------------------------------------------------------------+
//| Violation: Log, close, notify — NO counting, NO cooldown        |
//| Called ONLY from OnTradeTransaction                              |
//+------------------------------------------------------------------+
void Violation(string reason)
{
   Log("VIOLATION", reason);
   CloseAll(reason);
   if(Enable_Alerts) Alert("GRANDMASTER VIOLATION: " + reason);
   if(Enable_Push)   SendNotification("GRANDMASTER VIOLATION: " + reason);
}

//+------------------------------------------------------------------+
//| ViolationReason: Returns violation reason or "" if trade valid   |
//| Priority order: AfterFC > one-shot-used > outside-kill-zone      |
//| CRITICAL: g_trade_taken=true means an ENTRY was already accepted.|
//| Running positions with g_trade_taken=true are NEVER rejected.    |
//+------------------------------------------------------------------+
string ViolationReason(datetime ny, datetime today)
{
   if(AfterFC(ny))     return "POST_FORCE_CLOSE";
   if(g_trade_taken)   return "ONE_SHOT_ALREADY_USED";
   if(!InKillZone(ny)) return "OUTSIDE_KILL_ZONE";
   return "";
}

//+------------------------------------------------------------------+
//| UpdateState: 4-state machine — no BLOCKED state                 |
//+------------------------------------------------------------------+
void UpdateState(datetime ny, datetime today)
{
   EState prev = g_state;
   if(AfterFC(ny))         g_state = ST_FORCE_ZONE;
   else if(g_trade_taken)  g_state = ST_LOCKED;
   else if(InKillZone(ny)) g_state = ST_KZ_ACTIVE;
   else                    g_state = ST_PRE_KZ;

   if(g_state != prev)
      Log("STATE_CHANGE", EnumToString(g_state));
}

//+------------------------------------------------------------------+
//| ApplyChart: Set background color based on current state         |
//+------------------------------------------------------------------+
void ApplyChart(datetime ny, datetime today)
{
   color bg;
   switch(g_state)
   {
      case ST_KZ_ACTIVE:  bg = Color_KZ;        break;
      case ST_LOCKED:     bg = Color_Locked;    break;
      case ST_FORCE_ZONE: bg = Color_ForceZone; break;
      default:            bg = Color_PreKZ;     break;
   }
   if(ChartGetInteger(0, CHART_COLOR_BACKGROUND) != (long)bg)
   {
      ChartSetInteger(0, CHART_COLOR_BACKGROUND, bg);
      ChartRedraw();
   }
}

//+------------------------------------------------------------------+
//| PersistAll: Save all state to GlobalVariables                   |
//+------------------------------------------------------------------+
void PersistAll()
{
   GlobalVariableSet(GV_TRADE_DAY, (double)g_trade_day);
   GlobalVariableSet(GV_RESET_DAY, (double)g_last_reset_day);
   GlobalVariableSet(GV_FC_DONE,   g_fc_done_today ? 1.0 : 0.0);
}

//+------------------------------------------------------------------+
//| LoadMemory: Restore state from GlobalVariables after restart     |
//+------------------------------------------------------------------+
void LoadMemory()
{
   g_trade_day      = GlobalVariableCheck(GV_TRADE_DAY)
                      ? (datetime)GlobalVariableGet(GV_TRADE_DAY) : 0;
   g_last_reset_day = GlobalVariableCheck(GV_RESET_DAY)
                      ? (datetime)GlobalVariableGet(GV_RESET_DAY) : 0;
   g_fc_done_today  = GlobalVariableCheck(GV_FC_DONE)
                      ? (GlobalVariableGet(GV_FC_DONE) > 0.5) : false;

   datetime today = TodayNY();
   g_trade_taken   = (g_trade_day == today);

   Log("MEMORY_LOADED",
       "trade_day="    + TimeToString(g_trade_day, TIME_DATE) +
       " trade_taken=" + (string)g_trade_taken +
       " fc_done="     + (string)g_fc_done_today);
}

//+------------------------------------------------------------------+
//| DailyReset: Fires exactly once per NY day                       |
//| Stamps reset day FIRST — crash safety                           |
//+------------------------------------------------------------------+
void DailyReset(datetime today)
{
   if(g_last_reset_day == today) return;

   // Stamp reset day as VERY FIRST action (crash-safe)
   g_last_reset_day = today;
   GlobalVariableSet(GV_RESET_DAY, (double)today);

   // Reset daily-only state
   g_fc_done_today    = false;
   g_fc_first_attempt = 0;
   g_kz_was_active    = false;
   g_trade_taken      = (g_trade_day == today); // preserve if same day

   PersistAll();
   Log("DAILY_RESET", TimeToString(today, TIME_DATE));
}

//+------------------------------------------------------------------+
//| CheckDSTReminder: Warn of upcoming DST clock change             |
//+------------------------------------------------------------------+
void CheckDSTReminder(datetime ny)
{
   MqlDateTime d;
   TimeToStruct(ny, d);
   int y = d.year;
   if(g_dst_year == y) return; // Already processed this year

   datetime gmt = TimeGMT();

   // Spring forward: 2nd Sunday March at 07:00 UTC
   datetime march1 = MakeTime(y, 3, 1);
   MqlDateTime m1; TimeToStruct(march1, m1);
   int dow = m1.day_of_week;
   int ssm = (dow == 0) ? 1 : 1 + (7 - dow);
   datetime spring = MakeTime(y, 3, ssm + 7, 7);

   // Fall back: 1st Sunday November at 06:00 UTC
   datetime nov1 = MakeTime(y, 11, 1);
   MqlDateTime n1; TimeToStruct(nov1, n1);
   dow = n1.day_of_week;
   int fsn = (dow == 0) ? 1 : 1 + (7 - dow);
   datetime fall = MakeTime(y, 11, fsn, 6);

   int remind_secs = DST_Remind_Days * 86400;

   if(!g_dst_spring && gmt >= spring - remind_secs && gmt < spring)
   {
      g_dst_spring = true;
      string msg = "DST SPRING FORWARD in " + IntegerToString(DST_Remind_Days)
                 + " days — clocks go forward 1hr";
      Log("DST_REMINDER", msg);
      if(Enable_Alerts) Alert("[GMG] " + msg);
      if(Enable_Push)   SendNotification("[GMG] " + msg);
   }
   if(!g_dst_fall && gmt >= fall - remind_secs && gmt < fall)
   {
      g_dst_fall = true;
      string msg = "DST FALL BACK in " + IntegerToString(DST_Remind_Days)
                 + " days — clocks go back 1hr";
      Log("DST_REMINDER", msg);
      if(Enable_Alerts) Alert("[GMG] " + msg);
      if(Enable_Push)   SendNotification("[GMG] " + msg);
   }

   // Reset for next year once fall transition passes
   if(gmt > fall)
   {
      g_dst_spring = false;
      g_dst_fall   = false;
      g_dst_year   = y;
   }
}

//+------------------------------------------------------------------+
//| ForceCloseCheck: Execute 16:30 NY force close with alert        |
//+------------------------------------------------------------------+
void ForceCloseCheck(datetime ny)
{
   if(!AfterFC(ny)) return;
   if(g_fc_done_today && PositionsTotal() == 0) return;

   if(PositionsTotal() > 0)
   {
      if(g_fc_first_attempt == 0)
         g_fc_first_attempt = TimeCurrent();

      CloseAll("FORCE_CLOSE_16:30");

      // Escalating alert if broker repeatedly rejects the close order
      int elapsed = (int)(TimeCurrent() - g_fc_first_attempt);
      if(elapsed > 60)
      {
         string warn = "FORCE CLOSE FAILING for " + IntegerToString(elapsed)
                     + "s — MANUAL ACTION REQUIRED";
         Log("FC_ALERT", warn);
         if(Enable_Alerts) Alert("[GMG] " + warn);
         if(Enable_Push)   SendNotification("[GMG] " + warn);
      }
   }
   else
   {
      if(!g_fc_done_today)
      {
         g_fc_done_today = true;
         GlobalVariableSet(GV_FC_DONE, 1.0);
         Log("FC_COMPLETE", TimeToString(ny, TIME_DATE | TIME_MINUTES));
      }
   }
}

//+------------------------------------------------------------------+
//| KillZoneEdgeNotify: Notify on KZ open/close transitions         |
//+------------------------------------------------------------------+
void KillZoneEdgeNotify(datetime ny)
{
   bool active = InKillZone(ny);

   if(active && !g_kz_was_active)
   {
      string msg = "KILL ZONE OPEN — 9:30 AM NY. One trade slot available.";
      Log("KZ_OPEN", msg);
      if(Enable_Alerts) Alert("[GMG] " + msg);
      if(Enable_Push)   SendNotification("[GMG] " + msg);
   }
   if(!active && g_kz_was_active && !AfterFC(ny))
   {
      string msg = "KILL ZONE CLOSED — 11:00 AM NY. Entry window shut.";
      Log("KZ_CLOSED", msg);
      if(Enable_Alerts) Alert("[GMG] " + msg);
      if(Enable_Push)   SendNotification("[GMG] " + msg);
   }

   g_kz_was_active = active;
}

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   // Build GV key names with symbol prefix — avoids cross-symbol GV conflicts
   string sym = Symbol();
   GV_TRADE_DAY = "GMG_" + sym + "_TRADE_DAY";
   GV_RESET_DAY = "GMG_" + sym + "_RESET_DAY";
   GV_FC_DONE   = "GMG_" + sym + "_FC_DONE";

   trade.SetExpertMagicNumber(0); // Enforce ALL positions on this symbol

   LoadMemory();

   datetime ny    = NyTime();
   datetime today = TodayNY();

   DailyReset(today);
   UpdateState(ny, today);

   // Position guard: if a position is already open but no trade record exists,
   // consume the one-shot slot to prevent a second trade this session
   if(PositionsTotal() > 0 && !g_trade_taken)
   {
      g_trade_taken = true;
      g_trade_day   = today;
      PersistAll();
      Log("INIT_GUARD", "Open position detected on attach — trade slot consumed");
   }

   ApplyChart(ny, today);

   EventSetTimer(1); // 1-second heartbeat timer
   Log("INIT", "Elite Grandmaster Guard v3.2 MINIMALIST | Symbol=" + sym);
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit: Persist state and restore chart background            |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   PersistAll(); // MUST be first line

   EventKillTimer();

   // Restore neutral chart background on EA removal
   ChartSetInteger(0, CHART_COLOR_BACKGROUND, clrBlack);
   ChartRedraw();

   Log("DEINIT", "Reason=" + IntegerToString(reason));
}

//+------------------------------------------------------------------+
//| CoreEnforcement: Shared enforcement logic for OnTick + OnTimer  |
//|                                                                  |
//| DESIGN: Safety nets call CloseAll() directly — NOT Violation()  |
//|         Violation() is reserved for OnTradeTransaction ONLY     |
//|                                                                  |
//| CRITICAL TRADE MANAGEMENT RULE:                                  |
//| Once g_trade_taken is true, the position is valid and runs       |
//| freely — it will NEVER be closed by kill zone logic.            |
//| Only AfterFC (16:30) triggers force close on a valid position.  |
//+------------------------------------------------------------------+
void CoreEnforcement()
{
   if(IsWeekend(NyTime())) return;

   datetime ny    = NyTime();
   datetime today = TodayNY();

   DailyReset(today);
   CheckDSTReminder(ny);
   KillZoneEdgeNotify(ny);
   ForceCloseCheck(ny);
   UpdateState(ny, today);
   ApplyChart(ny, today);

   // Safety net: position exists outside the kill zone AND no trade has been
   // recorded — this position is invalid (opened before g_trade_taken was set).
   // If g_trade_taken is true, the position is the VALID one-shot trade and
   // must run freely; this safety net does NOT touch it.
   if(!g_trade_taken && !InKillZone(ny) && !AfterFC(ny) && PositionsTotal() > 0)
      CloseAll("SAFETY_NET_OUTSIDE_KZ");
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   CoreEnforcement();
}

//+------------------------------------------------------------------+
//| OnTimer: 1-second heartbeat for low-tick instruments            |
//+------------------------------------------------------------------+
void OnTimer()
{
   CoreEnforcement();
}

//+------------------------------------------------------------------+
//| OnTradeTransaction: SOLE caller of Violation()                   |
//| Fires on every deal; we check DEAL_ENTRY_IN only (new entries)  |
//| DEAL_ENTRY_OUT (SL / TP / manual close) are filtered out       |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction& trans,
                        const MqlTradeRequest&     req,
                        const MqlTradeResult&      res)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD) return;

   // trans.entry does NOT exist in MqlTradeTransaction — use HistoryDealGetInteger
   if(!HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetString(trans.deal, DEAL_SYMBOL) != Symbol()) return;

   ENUM_DEAL_ENTRY entry =
      (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);

   if(entry != DEAL_ENTRY_IN) return; // Ignore exits — valid trade keeps running

   datetime ny    = NyTime();
   datetime today = TodayNY();

   string reason = ViolationReason(ny, today);
   if(reason != "")
   {
      Violation(reason);
      return;
   }

   // Valid trade — record and lock the one-shot slot for today
   g_trade_taken = true;
   g_trade_day   = today;
   PersistAll();
   Log("TRADE_ACCEPTED", "Deal=" + IntegerToString(trans.deal));
}
//+------------------------------------------------------------------+
