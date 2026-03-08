//+------------------------------------------------------------------+
//|                                           DeflectonHistogram.mq5 |
//|                                  Copyright 2026, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "2.00"
#property indicator_separate_window
#property indicator_minimum 0.0
#property indicator_maximum 100.0
#property indicator_buffers 16
#property indicator_plots   6
#property indicator_label1  "BB Compression"
#property indicator_type1   DRAW_COLOR_HISTOGRAM
#property indicator_color1  clrLime, clrRed
#property indicator_width1  2
#property indicator_label2  "Compression MA"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrOrange
#property indicator_width2  1
#property indicator_label3  "RevPreUp"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrGold
#property indicator_width3  1
#property indicator_label4  "RevPreDown"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrGold
#property indicator_width4  1
#property indicator_label5  "RevConfUp"
#property indicator_type5   DRAW_ARROW
#property indicator_color5  clrLime
#property indicator_width5  1
#property indicator_label6  "RevConfDown"
#property indicator_type6   DRAW_ARROW
#property indicator_color6  clrRed
#property indicator_width6  1

enum ENUM_COMPRESSION_PLOT_MODE
  {
   COMPRESSION_AS_HISTOGRAM = 0,
   COMPRESSION_AS_LINE      = 1
  };

enum ENUM_REV_OUTPUT_MODE
  {
   REV_OUT_PRE_AND_CONFIRMED = 0,
   REV_OUT_CONFIRMED_ONLY    = 1
  };

enum ENUM_REV_STATE_MODE
  {
   REV_STATE_2 = 0,
   REV_STATE_3 = 1
  };

input int                InpBandsPeriod       = 17;
input int                InpBandsShift        = 0;
input double             InpBandsDeviation    = 1;
input ENUM_APPLIED_PRICE InpBandsAppliedPrice = PRICE_CLOSE;
input bool               InpShowBandsOnMainChart = true;
input int                InpNormalizePeriod   = 17;
input ENUM_COMPRESSION_PLOT_MODE InpCompressionPlotMode = COMPRESSION_AS_HISTOGRAM;
input int                InpMAPeriod          = 9;
input bool               InpInvertCompression = false;
input bool               InpOnlyReversalSignal = false; // Modo limpo opcional: apenas seta de inversao confirmada

input group "Reversal Engine"
input bool               InpRevEnable         = true;
input ENUM_REV_OUTPUT_MODE InpRevOutputMode   = REV_OUT_CONFIRMED_ONLY;
input ENUM_REV_STATE_MODE InpRevStateMode     = REV_STATE_3;
input int                InpRevFastLen        = 5;
input int                InpRevSlowLen        = 13;
input double             InpRevDeadbandPct    = 8.0;
input double             InpRevHysteresisPct  = 4.0;
input int                InpRevConfirmBars    = 1;
input bool               InpRevUseGeom        = true;
input bool               InpRevUseCusum       = true;
input bool               InpRevUseParityPrice = true;
input int                InpRevMinVotesPre    = 2;
input int                InpRevMinVotesConfirm= 2;

input group "Reversal Evaluation"
input int                InpEvalWindowBars    = 48;
input double             InpEvalMovePctRange  = 18.0;
input double             InpEvalFailPctRange  = 9.0;
input bool               InpRevShowDiagnostics= false;

double g_histogram[];
double g_histogram_color[];
double g_ma[];
double g_rev_pre_up[];
double g_rev_pre_down[];
double g_rev_conf_up[];
double g_rev_conf_down[];
double g_rev_state[];
double g_rev_pre_sig[];
double g_rev_conf_sig[];
double g_rev_confidence[];
double g_rev_engine_geom[];
double g_rev_engine_cusum[];
double g_rev_engine_parity[];
double g_cusum_pos[];
double g_cusum_neg[];
double g_upper[];
double g_lower[];
int    g_bands_handle = INVALID_HANDLE;
string g_bands_shortname = "";
bool   g_bands_added_to_main_chart = false;

int    g_eval_geom_hits = 0;
int    g_eval_geom_fails = 0;
double g_eval_geom_avg_delay = 0.0;
int    g_eval_cusum_hits = 0;
int    g_eval_cusum_fails = 0;
double g_eval_cusum_avg_delay = 0.0;
int    g_eval_parity_hits = 0;
int    g_eval_parity_fails = 0;
double g_eval_parity_avg_delay = 0.0;

//+------------------------------------------------------------------+
//| Clamp a value into [0,100]                                       |
//+------------------------------------------------------------------+
double ClampScore(double value)
  {
   if(value < 0.0)
      return 0.0;
   if(value > 100.0)
      return 100.0;
   return value;
  }

//+------------------------------------------------------------------+
int SignOf(const double x)
  {
   if(x > 0.0) return 1;
   if(x < 0.0) return -1;
   return 0;
  }

//+------------------------------------------------------------------+
double RobustDiffScaleAt(const double &src[], const int i, const int bars_available, const int len)
  {
   const double eps = 1e-9;
   int maxn = MathMin(len, bars_available - i - 1);
   if(maxn <= 1)
      return eps;

   double vals[];
   if(ArrayResize(vals, maxn) != maxn)
      return eps;

   int n = 0;
   for(int k = 0; k < maxn; ++k)
     {
      int idx = i + k;
      if(idx + 1 >= bars_available)
         break;
      if(src[idx] == EMPTY_VALUE || src[idx + 1] == EMPTY_VALUE)
         continue;
      vals[n++] = MathAbs(src[idx] - src[idx + 1]);
     }
   if(n <= 0)
      return eps;
   ArrayResize(vals, n);
   ArraySort(vals);
   if((n % 2) == 1)
      return MathMax(vals[n / 2], eps);
   return MathMax(0.5 * (vals[n / 2 - 1] + vals[n / 2]), eps);
  }

//+------------------------------------------------------------------+
void EvaluateEngineSignals(const int bars_available,
                           const double &high[],
                           const double &low[],
                           const double &close[],
                           const double &engine_sig[],
                           int &hits,
                           int &fails,
                           double &avg_delay)
  {
   hits = 0;
   fails = 0;
   avg_delay = 0.0;
   double delay_sum = 0.0;

   if(InpEvalWindowBars < 2 || bars_available < 5)
      return;

   for(int i = bars_available - 2; i >= 2; --i)
     {
      int sig = (int)engine_sig[i];
      if(sig == 0)
         continue;
      if((int)engine_sig[i + 1] == sig)
         continue;

      int stop = i - InpEvalWindowBars;
      if(stop < 0)
         stop = 0;
      if(i - 1 < stop)
         continue;

      double max_h = high[i - 1];
      double min_l = low[i - 1];
      for(int j = i - 1; j >= stop; --j)
        {
         if(high[j] > max_h) max_h = high[j];
         if(low[j] < min_l)  min_l = low[j];
        }
      double local_range = max_h - min_l;
      if(local_range <= 0.0)
         continue;

      double move_thr = local_range * (InpEvalMovePctRange / 100.0);
      double fail_thr = local_range * (InpEvalFailPctRange / 100.0);
      double entry = close[i];
      bool resolved = false;

      for(int j = i - 1; j >= stop; --j)
        {
         double favorable = 0.0;
         double adverse = 0.0;
         if(sig > 0)
           {
            favorable = high[j] - entry;
            adverse = entry - low[j];
           }
         else
           {
            favorable = entry - low[j];
            adverse = high[j] - entry;
           }

         if(favorable >= move_thr)
           {
            hits++;
            delay_sum += (double)(i - j);
            resolved = true;
            break;
           }
         if(adverse >= fail_thr)
           {
            fails++;
            resolved = true;
            break;
           }
        }
      if(!resolved)
         continue;
     }

   if(hits > 0)
      avg_delay = delay_sum / (double)hits;
  }
//| Configura modo de plot do indicador principal                    |
//+------------------------------------------------------------------+
void SetupCompressionPlotMode()
  {
   if(InpCompressionPlotMode == COMPRESSION_AS_LINE)
     {
      PlotIndexSetInteger(0,PLOT_DRAW_TYPE,DRAW_COLOR_LINE);
      PlotIndexSetInteger(0,PLOT_LINE_WIDTH,1);
     }
   else
     {
      PlotIndexSetInteger(0,PLOT_DRAW_TYPE,DRAW_COLOR_HISTOGRAM);
      PlotIndexSetInteger(0,PLOT_LINE_WIDTH,2);
     }
  }
//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
  {
//--- indicator buffers mapping
   SetIndexBuffer(0,g_histogram,INDICATOR_DATA);
   SetIndexBuffer(1,g_histogram_color,INDICATOR_COLOR_INDEX);
   SetIndexBuffer(2,g_ma,INDICATOR_DATA);
   SetIndexBuffer(3,g_rev_pre_up,INDICATOR_DATA);
   SetIndexBuffer(4,g_rev_pre_down,INDICATOR_DATA);
   SetIndexBuffer(5,g_rev_conf_up,INDICATOR_DATA);
   SetIndexBuffer(6,g_rev_conf_down,INDICATOR_DATA);
   SetIndexBuffer(7,g_rev_state,INDICATOR_CALCULATIONS);
   SetIndexBuffer(8,g_rev_pre_sig,INDICATOR_CALCULATIONS);
   SetIndexBuffer(9,g_rev_conf_sig,INDICATOR_CALCULATIONS);
   SetIndexBuffer(10,g_rev_confidence,INDICATOR_CALCULATIONS);
   SetIndexBuffer(11,g_rev_engine_geom,INDICATOR_CALCULATIONS);
   SetIndexBuffer(12,g_rev_engine_cusum,INDICATOR_CALCULATIONS);
   SetIndexBuffer(13,g_rev_engine_parity,INDICATOR_CALCULATIONS);
   SetIndexBuffer(14,g_cusum_pos,INDICATOR_CALCULATIONS);
   SetIndexBuffer(15,g_cusum_neg,INDICATOR_CALCULATIONS);

   ArraySetAsSeries(g_histogram,true);
   ArraySetAsSeries(g_histogram_color,true);
   ArraySetAsSeries(g_ma,true);
   ArraySetAsSeries(g_rev_pre_up,true);
   ArraySetAsSeries(g_rev_pre_down,true);
   ArraySetAsSeries(g_rev_conf_up,true);
   ArraySetAsSeries(g_rev_conf_down,true);
   ArraySetAsSeries(g_rev_state,true);
   ArraySetAsSeries(g_rev_pre_sig,true);
   ArraySetAsSeries(g_rev_conf_sig,true);
   ArraySetAsSeries(g_rev_confidence,true);
   ArraySetAsSeries(g_rev_engine_geom,true);
   ArraySetAsSeries(g_rev_engine_cusum,true);
   ArraySetAsSeries(g_rev_engine_parity,true);
   ArraySetAsSeries(g_cusum_pos,true);
   ArraySetAsSeries(g_cusum_neg,true);

   PlotIndexSetDouble(0,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   PlotIndexSetDouble(1,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   PlotIndexSetDouble(2,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   PlotIndexSetDouble(3,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   PlotIndexSetDouble(4,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   PlotIndexSetDouble(5,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   PlotIndexSetInteger(0,PLOT_COLOR_INDEXES,2);
   PlotIndexSetInteger(0,PLOT_LINE_COLOR,0,clrLime);
   PlotIndexSetInteger(0,PLOT_LINE_COLOR,1,clrRed);
   PlotIndexSetInteger(2,PLOT_ARROW,233); // up
   PlotIndexSetInteger(3,PLOT_ARROW,234); // down
   PlotIndexSetInteger(4,PLOT_ARROW,241); // confirmed up
   PlotIndexSetInteger(5,PLOT_ARROW,242); // confirmed down
   SetupCompressionPlotMode();

   if(InpOnlyReversalSignal)
     {
      PlotIndexSetInteger(0, PLOT_DRAW_TYPE, DRAW_NONE);
      PlotIndexSetInteger(1, PLOT_DRAW_TYPE, DRAW_NONE);
      PlotIndexSetInteger(2, PLOT_DRAW_TYPE, DRAW_NONE);
      PlotIndexSetInteger(3, PLOT_DRAW_TYPE, DRAW_NONE);
      PlotIndexSetInteger(4, PLOT_DRAW_TYPE, InpRevEnable ? DRAW_ARROW : DRAW_NONE);
      PlotIndexSetInteger(5, PLOT_DRAW_TYPE, InpRevEnable ? DRAW_ARROW : DRAW_NONE);
     }
   else
     {
      PlotIndexSetInteger(2, PLOT_DRAW_TYPE, InpRevEnable && InpRevOutputMode == REV_OUT_PRE_AND_CONFIRMED ? DRAW_ARROW : DRAW_NONE);
      PlotIndexSetInteger(3, PLOT_DRAW_TYPE, InpRevEnable && InpRevOutputMode == REV_OUT_PRE_AND_CONFIRMED ? DRAW_ARROW : DRAW_NONE);
      PlotIndexSetInteger(4, PLOT_DRAW_TYPE, InpRevEnable ? DRAW_ARROW : DRAW_NONE);
      PlotIndexSetInteger(5, PLOT_DRAW_TYPE, InpRevEnable ? DRAW_ARROW : DRAW_NONE);
     }

   IndicatorSetString(INDICATOR_SHORTNAME,
                      StringFormat("BB Compression (%d, %.2f) + MA(%d) [0..100]",
                                   InpBandsPeriod,
                                   InpBandsDeviation,
                                   InpMAPeriod));

   if(InpNormalizePeriod < 1)
     {
      Print("InpNormalizePeriod precisa ser >= 1.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMAPeriod < 1)
     {
      Print("InpMAPeriod precisa ser >= 1.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpRevFastLen < 2 || InpRevSlowLen < 3 || InpRevFastLen >= InpRevSlowLen)
     {
      Print("Reversal: use InpRevFastLen >=2, InpRevSlowLen >=3 e Fast < Slow.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpRevDeadbandPct <= 0.0 || InpRevHysteresisPct < 0.0)
     {
      Print("Reversal: deadband/histerese invalidos.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpRevConfirmBars < 1 || InpRevConfirmBars > 10)
     {
      Print("Reversal: InpRevConfirmBars deve estar entre 1 e 10.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpRevMinVotesPre < 1 || InpRevMinVotesConfirm < 1)
     {
      Print("Reversal: votos minimos devem ser >= 1.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(!InpRevUseGeom && !InpRevUseCusum && !InpRevUseParityPrice)
     {
      Print("Reversal: habilite pelo menos um motor (Geom/Cusum/Parity).");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpRevMinVotesPre > 3 || InpRevMinVotesConfirm > 3)
     {
      Print("Reversal: votos minimos acima do numero maximo de motores (3).");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpEvalWindowBars < 4 || InpEvalMovePctRange <= 0.0 || InpEvalFailPctRange <= 0.0)
     {
      Print("Reversal eval: parametros invalidos.");
      return INIT_PARAMETERS_INCORRECT;
     }

   g_bands_handle = iBands(_Symbol,
                           PERIOD_CURRENT,
                           InpBandsPeriod,
                           InpBandsShift,
                           InpBandsDeviation,
                           InpBandsAppliedPrice);

   if(g_bands_handle == INVALID_HANDLE)
     {
      PrintFormat("Falha ao criar iBands. Erro=%d",GetLastError());
      return INIT_FAILED;
     }

   if(InpShowBandsOnMainChart)
     {
      int indicators_before = ChartIndicatorsTotal(ChartID(),0);

      if(ChartIndicatorAdd(ChartID(),0,g_bands_handle))
        {
         g_bands_added_to_main_chart = true;

         int indicators_after = ChartIndicatorsTotal(ChartID(),0);
         if(indicators_after > indicators_before)
            g_bands_shortname = ChartIndicatorName(ChartID(),0,indicators_after - 1);
        }
      else
        {
         PrintFormat("Falha ao adicionar Bollinger no grafico principal. Erro=%d",
                     GetLastError());
        }
     }
//---
   return(INIT_SUCCEEDED);
  }
//+------------------------------------------------------------------+
//| Indicator deinitialization                                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_bands_added_to_main_chart && g_bands_shortname != "")
      ChartIndicatorDelete(ChartID(),0,g_bands_shortname);

   if(g_bands_handle != INVALID_HANDLE)
     {
      IndicatorRelease(g_bands_handle);
      g_bands_handle = INVALID_HANDLE;
     }
  }
//+------------------------------------------------------------------+
//| Custom indicator iteration function                              |
//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
  {
//---
   if(rates_total <= 0 || g_bands_handle == INVALID_HANDLE)
      return 0;
   ArraySetAsSeries(open,true);
   ArraySetAsSeries(high,true);
   ArraySetAsSeries(low,true);
   ArraySetAsSeries(close,true);

   if(ArrayResize(g_upper,rates_total) != rates_total ||
      ArrayResize(g_lower,rates_total) != rates_total)
      return prev_calculated;
   ArraySetAsSeries(g_upper,true);
   ArraySetAsSeries(g_lower,true);

   int copied_upper = CopyBuffer(g_bands_handle,1,0,rates_total,g_upper);
   int copied_lower = CopyBuffer(g_bands_handle,2,0,rates_total,g_lower);

   if(copied_upper <= 0 || copied_lower <= 0)
      return prev_calculated;

   int bars_available = MathMin(rates_total,MathMin(copied_upper,copied_lower));
   if(bars_available <= 0)
      return prev_calculated;

   // Limpa barras sem dados suficientes
   for(int i = rates_total - 1; i >= bars_available; i--)
     {
      g_histogram[i] = EMPTY_VALUE;
      g_histogram_color[i] = 0.0;
      g_ma[i] = EMPTY_VALUE;
      g_rev_pre_up[i] = EMPTY_VALUE;
      g_rev_pre_down[i] = EMPTY_VALUE;
      g_rev_conf_up[i] = EMPTY_VALUE;
      g_rev_conf_down[i] = EMPTY_VALUE;
      g_rev_state[i] = 0.0;
      g_rev_pre_sig[i] = 0.0;
      g_rev_conf_sig[i] = 0.0;
      g_rev_confidence[i] = 0.0;
      g_rev_engine_geom[i] = 0.0;
      g_rev_engine_cusum[i] = 0.0;
      g_rev_engine_parity[i] = 0.0;
      g_cusum_pos[i] = 0.0;
      g_cusum_neg[i] = 0.0;
     }

   for(int i = bars_available - 1; i >= 0; i--)
     {
      if(g_upper[i] == EMPTY_VALUE || g_lower[i] == EMPTY_VALUE)
        {
         g_histogram[i] = EMPTY_VALUE;
         g_histogram_color[i] = 0.0;
         continue;
        }

      double distance = g_upper[i] - g_lower[i];
      if(distance < 0.0)
         distance = 0.0;

      int end_index = i + InpNormalizePeriod - 1;
      if(end_index >= bars_available)
         end_index = bars_available - 1;

      double max_distance = 0.0;
      bool has_valid_distance = false;
      for(int j = i; j <= end_index; j++)
        {
         if(g_upper[j] == EMPTY_VALUE || g_lower[j] == EMPTY_VALUE)
            continue;

         double current_distance = g_upper[j] - g_lower[j];
         if(current_distance > max_distance)
            max_distance = current_distance;
         has_valid_distance = true;
        }

      if(!has_valid_distance)
        {
         g_histogram[i] = EMPTY_VALUE;
         g_histogram_color[i] = 0.0;
         continue;
        }

      double score = 100.0;
      if(max_distance > 0.0)
         score = 100.0 * (1.0 - (distance / max_distance));

      if(InpInvertCompression)
         score = 100.0 - score;

      g_histogram[i] = ClampScore(score);
      g_histogram_color[i] = (close[i] >= open[i]) ? 0.0 : 1.0;
     }

   // A media pode adicionar atraso visual, como qualquer smoothing.
   for(int i = bars_available - 1; i >= 0; i--)
     {
      if(g_histogram[i] == EMPTY_VALUE)
        {
         g_ma[i] = EMPTY_VALUE;
         continue;
        }

      int end_index = i + InpMAPeriod - 1;
      if(end_index >= bars_available)
         end_index = bars_available - 1;

      double sum = 0.0;
      int count = 0;
      for(int j = i; j <= end_index; j++)
        {
         if(g_histogram[j] == EMPTY_VALUE)
            continue;
         sum += g_histogram[j];
         count++;
        }

      if(count == 0)
         g_ma[i] = EMPTY_VALUE;
      else
         g_ma[i] = sum / count;
     }

   // Motor de reversao hibrido (pre barra 0 + confirmado em barras fechadas)
   for(int i = bars_available - 1; i >= 0; --i)
     {
      g_rev_pre_up[i] = EMPTY_VALUE;
      g_rev_pre_down[i] = EMPTY_VALUE;
      g_rev_conf_up[i] = EMPTY_VALUE;
      g_rev_conf_down[i] = EMPTY_VALUE;
      g_rev_state[i] = 0.0;
      g_rev_pre_sig[i] = 0.0;
      g_rev_conf_sig[i] = 0.0;
      g_rev_confidence[i] = 0.0;
      g_rev_engine_geom[i] = 0.0;
      g_rev_engine_cusum[i] = 0.0;
      g_rev_engine_parity[i] = 0.0;
      g_cusum_pos[i] = 0.0;
      g_cusum_neg[i] = 0.0;

      if(!InpRevEnable)
         continue;
      if(i + 2 >= bars_available)
         continue;

      const double b0 = (g_ma[i] != EMPTY_VALUE) ? g_ma[i] : g_histogram[i];
      const double b1 = (g_ma[i + 1] != EMPTY_VALUE) ? g_ma[i + 1] : g_histogram[i + 1];
      const double b2 = (g_ma[i + 2] != EMPTY_VALUE) ? g_ma[i + 2] : g_histogram[i + 2];
      if(b0 == EMPTY_VALUE || b1 == EMPTY_VALUE || b2 == EMPTY_VALUE)
         continue;

      int fast_shift = MathMin(InpRevFastLen, bars_available - i - 1);
      if(fast_shift < 1) fast_shift = 1;
      const double bf = (g_ma[i + fast_shift] != EMPTY_VALUE) ? g_ma[i + fast_shift] : g_histogram[i + fast_shift];
      if(bf == EMPTY_VALUE)
         continue;

      const double scale = RobustDiffScaleAt(g_histogram, i, bars_available, InpRevSlowLen);
      const double d1 = b0 - b1;
      const double d1_fast = b0 - bf;
      const double d1_prev = b1 - b2;
      const double d2 = d1 - d1_prev;
      const double dead = scale * (InpRevDeadbandPct / 100.0);
      const double hyst = scale * (InpRevHysteresisPct / 100.0);
      const double dead_geom = MathMax(dead, 1e-9);

      int sig_geom = 0;
      if(d1_prev <= dead_geom && d1 > dead_geom && d1_fast > dead_geom && d2 > 0.0)
         sig_geom = +1;
      else if(d1_prev >= -dead_geom && d1 < -dead_geom && d1_fast < -dead_geom && d2 < 0.0)
         sig_geom = -1;
      g_rev_engine_geom[i] = (double)sig_geom;

      const double delta = d1 / MathMax(scale, 1e-9);
      const double cusum_k = 0.15;
      const double cusum_h = 1.0;
      if(i == bars_available - 1)
        {
         g_cusum_pos[i] = 0.0;
         g_cusum_neg[i] = 0.0;
        }
      else
        {
         g_cusum_pos[i] = MathMax(0.0, g_cusum_pos[i + 1] + delta - cusum_k);
         g_cusum_neg[i] = MathMax(0.0, g_cusum_neg[i + 1] - delta - cusum_k);
        }
      int sig_cusum = 0;
      if(g_cusum_pos[i] > cusum_h && g_cusum_pos[i] > g_cusum_neg[i])
         sig_cusum = +1;
      else if(g_cusum_neg[i] > cusum_h && g_cusum_neg[i] > g_cusum_pos[i])
         sig_cusum = -1;
      g_rev_engine_cusum[i] = (double)sig_cusum;

      int sig_parity = 0;
      const double price_slope = close[i] - close[i + 1];
      if(d1 > (dead * 0.5) && price_slope > (_Point * 0.1))
         sig_parity = +1;
      else if(d1 < -(dead * 0.5) && price_slope < -(_Point * 0.1))
         sig_parity = -1;
      g_rev_engine_parity[i] = (double)sig_parity;

      int enabled = 0;
      int up_votes = 0;
      int down_votes = 0;
      if(InpRevUseGeom)
        {
         enabled++;
         if(sig_geom > 0) up_votes++;
         else if(sig_geom < 0) down_votes++;
        }
      if(InpRevUseCusum)
        {
         enabled++;
         if(sig_cusum > 0) up_votes++;
         else if(sig_cusum < 0) down_votes++;
        }
      if(InpRevUseParityPrice)
        {
         enabled++;
         if(sig_parity > 0) up_votes++;
         else if(sig_parity < 0) down_votes++;
        }
      if(enabled <= 0)
         enabled = 1;

      int pre_sig = 0;
      if(up_votes >= InpRevMinVotesPre && up_votes > down_votes)
         pre_sig = +1;
      else if(down_votes >= InpRevMinVotesPre && down_votes > up_votes)
         pre_sig = -1;
      g_rev_pre_sig[i] = (double)pre_sig;

      int conf_sig = 0;
      if(i >= 1 && pre_sig != 0)
        {
         bool persistent = true;
         for(int k = 1; k <= InpRevConfirmBars; ++k)
           {
            int idx = i + k;
            if(idx >= bars_available || (int)g_rev_pre_sig[idx] != pre_sig)
              {
               persistent = false;
               break;
              }
           }
         if(persistent)
           {
            const int dir_votes = (pre_sig > 0) ? up_votes : down_votes;
            if(dir_votes >= InpRevMinVotesConfirm)
               conf_sig = pre_sig;
           }
        }
      g_rev_conf_sig[i] = (double)conf_sig;

      int prev_state = (i + 1 < bars_available) ? (int)g_rev_state[i + 1] : 0;
      int curr_state = prev_state;
      if(InpRevStateMode == REV_STATE_2)
        {
         if(conf_sig != 0) curr_state = conf_sig;
         else if(pre_sig != 0) curr_state = pre_sig;
         else if(curr_state == 0) curr_state = SignOf(d1);
         if(curr_state == 0) curr_state = +1;
        }
      else
        {
         if(conf_sig != 0) curr_state = conf_sig;
         else if(pre_sig != 0) curr_state = pre_sig;
         else if(MathAbs(d1) <= (dead + hyst)) curr_state = 0;
         else if(d1 > (dead + hyst)) curr_state = +1;
         else if(d1 < -(dead + hyst)) curr_state = -1;
        }
      g_rev_state[i] = (double)curr_state;

      double conf = 100.0 * ((double)MathMax(up_votes, down_votes) / (double)enabled);
      if(conf_sig != 0)
         conf = MathMin(100.0, conf + 20.0);
      g_rev_confidence[i] = conf;

      bool show_pre = (InpRevOutputMode == REV_OUT_PRE_AND_CONFIRMED);
      if(show_pre && pre_sig > 0 && conf_sig == 0)
         g_rev_pre_up[i] = 88.0;
      else if(show_pre && pre_sig < 0 && conf_sig == 0)
         g_rev_pre_down[i] = 12.0;

      if(conf_sig > 0)
         g_rev_conf_up[i] = 96.0;
      else if(conf_sig < 0)
         g_rev_conf_down[i] = 4.0;
     }

   EvaluateEngineSignals(bars_available, high, low, close, g_rev_engine_geom,
                         g_eval_geom_hits, g_eval_geom_fails, g_eval_geom_avg_delay);
   EvaluateEngineSignals(bars_available, high, low, close, g_rev_engine_cusum,
                         g_eval_cusum_hits, g_eval_cusum_fails, g_eval_cusum_avg_delay);
   EvaluateEngineSignals(bars_available, high, low, close, g_rev_engine_parity,
                         g_eval_parity_hits, g_eval_parity_fails, g_eval_parity_avg_delay);

   if(InpRevShowDiagnostics)
     {
      string mode = (InpRevStateMode == REV_STATE_2 ? "S2" : "S3");
      int conf_closed = (bars_available > 1) ? (int)g_rev_conf_sig[1] : 0;
      string txt = StringFormat(
         "REV[%s] st=%d pre=%d conf=%d conf%%=%.0f | G h/f %d/%d d=%.1f | C %d/%d d=%.1f | P %d/%d d=%.1f",
         mode,
         (int)g_rev_state[0],
         (int)g_rev_pre_sig[0],
         conf_closed,
         g_rev_confidence[0],
         g_eval_geom_hits, g_eval_geom_fails, g_eval_geom_avg_delay,
         g_eval_cusum_hits, g_eval_cusum_fails, g_eval_cusum_avg_delay,
         g_eval_parity_hits, g_eval_parity_fails, g_eval_parity_avg_delay
      );
      Comment(txt);
     }
//--- return value of prev_calculated for next call
   return(rates_total);
  }
//+------------------------------------------------------------------+
