//+------------------------------------------------------------------+
//|                                           DeflectonHistogram.mq5 |
//|                                  Copyright 2026, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.01"
#property indicator_separate_window
#property indicator_minimum 0.0
#property indicator_maximum 100.0
#property indicator_buffers 2
#property indicator_plots   2
#property indicator_label1  "BB Compression"
#property indicator_type1   DRAW_HISTOGRAM
#property indicator_color1  clrDodgerBlue
#property indicator_width1  2
#property indicator_label2  "Compression MA"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrOrange
#property indicator_width2  1

enum ENUM_COMPRESSION_PLOT_MODE
  {
   COMPRESSION_AS_HISTOGRAM = 0,
   COMPRESSION_AS_LINE      = 1
  };

input int                InpBandsPeriod       = 5;
input int                InpBandsShift        = 0;
input double             InpBandsDeviation    = 1;
input ENUM_APPLIED_PRICE InpBandsAppliedPrice = PRICE_CLOSE;
input bool               InpShowBandsOnMainChart = true;
input int                InpNormalizePeriod   = 5;
input ENUM_COMPRESSION_PLOT_MODE InpCompressionPlotMode = COMPRESSION_AS_LINE;
input int                InpMAPeriod          = 5;
input bool               InpInvertCompression = false;

double g_histogram[];
double g_ma[];
double g_upper[];
double g_lower[];
int    g_bands_handle = INVALID_HANDLE;
string g_bands_shortname = "";
bool   g_bands_added_to_main_chart = false;

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
//| Configura modo de plot do indicador principal                    |
//+------------------------------------------------------------------+
void SetupCompressionPlotMode()
  {
   if(InpCompressionPlotMode == COMPRESSION_AS_LINE)
     {
      PlotIndexSetInteger(0,PLOT_DRAW_TYPE,DRAW_LINE);
      PlotIndexSetInteger(0,PLOT_LINE_WIDTH,1);
     }
   else
     {
      PlotIndexSetInteger(0,PLOT_DRAW_TYPE,DRAW_HISTOGRAM);
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
   SetIndexBuffer(1,g_ma,INDICATOR_DATA);
   ArraySetAsSeries(g_histogram,true);
   ArraySetAsSeries(g_ma,true);
   PlotIndexSetDouble(0,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   PlotIndexSetDouble(1,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   SetupCompressionPlotMode();

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
      g_ma[i] = EMPTY_VALUE;
     }

   for(int i = bars_available - 1; i >= 0; i--)
     {
      if(g_upper[i] == EMPTY_VALUE || g_lower[i] == EMPTY_VALUE)
        {
         g_histogram[i] = EMPTY_VALUE;
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
         continue;
        }

      double score = 100.0;
      if(max_distance > 0.0)
         score = 100.0 * (1.0 - (distance / max_distance));

      if(InpInvertCompression)
         score = 100.0 - score;

      g_histogram[i] = ClampScore(score);
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
//--- return value of prev_calculated for next call
   return(rates_total);
  }
//+------------------------------------------------------------------+
