//+------------------------------------------------------------------+
//|                                        DeflectonHistogram_v2.mq5 |
//|                                  Copyright 2026, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "2.00"
#property indicator_separate_window
#property indicator_buffers 3
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

enum ENUM_COMPRESSION_SCALE_MODE
  {
   COMPRESSION_SCALE_DYNAMIC = 0, // sem forcar 0..100 (recomendado)
   COMPRESSION_SCALE_0_100   = 1  // modo legado 0..100
  };

input int                InpBandsPeriod       = 9;     // Bollinger period (base do histograma)
input int                InpBandsShift        = 0;
input double             InpBandsDeviation    = 1;
input ENUM_APPLIED_PRICE InpBandsAppliedPrice = PRICE_CLOSE;
input bool               InpShowBandsOnMainChart = true;
input int                InpNormalizePeriod   = 9;     // Normalizacao do histograma (nao afeta a MA)
input ENUM_COMPRESSION_PLOT_MODE InpCompressionPlotMode = COMPRESSION_AS_HISTOGRAM;
input int                InpMAPeriod          = 9;     // Periodo da MA (nao altera o histograma)
input bool               InpInvertCompression = false;
input ENUM_COMPRESSION_SCALE_MODE InpScaleMode = COMPRESSION_SCALE_DYNAMIC; // Escala do output

double g_histogram[];
double g_ma[];
double g_histogram_raw[]; // buffer interno: compressao final antes da media
double g_upper[];
double g_lower[];
int    g_bands_handle = INVALID_HANDLE;
string g_bands_shortname = "";
bool   g_bands_added_to_main_chart = false;

//+------------------------------------------------------------------+
//| Clamp a value into [0,1]                                         |
//+------------------------------------------------------------------+
double ClampUnit(double value)
  {
   if(value < 0.0)
      return 0.0;
   if(value > 1.0)
      return 1.0;
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
   SetIndexBuffer(2,g_histogram_raw,INDICATOR_CALCULATIONS);
   ArraySetAsSeries(g_histogram,true);
   ArraySetAsSeries(g_ma,true);
   ArraySetAsSeries(g_histogram_raw,true);
   PlotIndexSetDouble(0,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   PlotIndexSetDouble(1,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   SetupCompressionPlotMode();

   string scale_label = (InpScaleMode == COMPRESSION_SCALE_0_100) ? "0..100" : "dinamica";
   IndicatorSetString(INDICATOR_SHORTNAME,
                      StringFormat("BB Compression v2 (%d, %.2f) + MA(%d) [%s]",
                                   InpBandsPeriod,
                                   InpBandsDeviation,
                                   InpMAPeriod,
                                   scale_label));

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
      g_histogram_raw[i] = EMPTY_VALUE;
      g_ma[i] = EMPTY_VALUE;
     }

   for(int i = bars_available - 1; i >= 0; i--)
     {
      if(g_upper[i] == EMPTY_VALUE || g_lower[i] == EMPTY_VALUE)
        {
         g_histogram_raw[i] = EMPTY_VALUE;
         g_histogram[i] = EMPTY_VALUE;
         continue;
        }

      double distance = g_upper[i] - g_lower[i];
      if(distance < 0.0)
         distance = 0.0;

      int end_index = i + InpNormalizePeriod - 1;
      if(end_index >= bars_available)
         end_index = bars_available - 1;

      int valid_count = 0;
      int less_count = 0;
      int equal_count = 0;
      for(int j = i; j <= end_index; j++)
        {
         if(g_upper[j] == EMPTY_VALUE || g_lower[j] == EMPTY_VALUE)
            continue;

         double current_distance = g_upper[j] - g_lower[j];
         valid_count++;

         if(current_distance < distance)
            less_count++;
         else
           {
            if(current_distance == distance)
               equal_count++;
           }
        }

      if(valid_count <= 0)
        {
         g_histogram_raw[i] = EMPTY_VALUE;
         g_histogram[i] = EMPTY_VALUE;
         continue;
        }

      // Percentil local da abertura:
      // minimo -> ~0, maximo -> ~1, sem bater exatamente nos extremos.
      double openness = ((double)less_count + 0.5 * (double)equal_count) / (double)valid_count;

      openness = ClampUnit(openness);
      double compression = 1.0 - openness;
      double score = InpInvertCompression ? openness : compression;

      if(InpScaleMode == COMPRESSION_SCALE_0_100)
         score *= 100.0;

      g_histogram_raw[i] = score;
      g_histogram[i] = g_histogram_raw[i];
     }

   // MA totalmente separada do histograma visual:
   // usa somente o buffer interno g_histogram_raw.
   for(int i = bars_available - 1; i >= 0; i--)
     {
      if(g_histogram_raw[i] == EMPTY_VALUE)
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
         if(g_histogram_raw[j] == EMPTY_VALUE)
            continue;
         sum += g_histogram_raw[j];
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
