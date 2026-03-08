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
#property indicator_buffers 7
#property indicator_plots   6
#property indicator_label1  "BB Compression"
#property indicator_type1   DRAW_COLOR_HISTOGRAM
#property indicator_color1  clrDodgerBlue,clrSilver,clrTomato
#property indicator_width1  2
#property indicator_label2  "Compression MA"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrOrange
#property indicator_width2  1
#property indicator_label3  "Wave Hole"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrMagenta
#property indicator_width3  3
#property indicator_label4  "Wave Peak"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrMagenta
#property indicator_width4  3
#property indicator_label5  "Zero Start"
#property indicator_type5   DRAW_ARROW
#property indicator_color5  clrMagenta
#property indicator_width5  2
#property indicator_label6  "Zero End"
#property indicator_type6   DRAW_ARROW
#property indicator_color6  clrMagenta
#property indicator_width6  2

#include "Compress_v2.5.Diagnostics.mqh"

enum ENUM_COMPRESSION_PLOT_MODE
  {
   COMPRESSION_AS_HISTOGRAM = 0,
   COMPRESSION_AS_LINE      = 1
  };

enum ENUM_DIAG_MARKER_VIEW_MODE
  {
   DIAG_MARKERS_ALL        = 0,
   DIAG_MARKERS_HOLES_ONLY = 1,
   DIAG_MARKERS_PEAKS_ONLY = 2,
   DIAG_MARKERS_ZERO_ONLY  = 3
  };

input group "01. Bollinger e Compression"
input int                InpBandsPeriod       = 9;
input int                InpBandsShift        = 0;
input double             InpBandsDeviation    = 2;
input ENUM_APPLIED_PRICE InpBandsAppliedPrice = PRICE_CLOSE;
input bool               InpShowBandsOnMainChart = true;
input int                InpNormalizePeriod   = 9;
input ENUM_COMPRESSION_PLOT_MODE InpCompressionPlotMode = COMPRESSION_AS_LINE;
input int                InpMAPeriod          = 9;
input bool               InpInvertCompression = true; // inversao

input group "02. Tendencia e Cores"
input int                InpTrendMAPeriod     = 9;
input int                InpTrendSlopeLookback = 3;
input double             InpTrendSlopeNeutral = 0.0;
input bool               InpTrendUsePriceFilter = true;
input color              InpWaveColorTrade    = clrLimeGreen;
input color              InpWaveColorCounterTrend = clrTomato;
input color              InpWaveColorNoTrend  = clrSilver;

input group "03. Regras de Wave"
input bool               InpShowWaveMarkers   = true;
input bool               InpShowPeakMarkers   = true;
input double             InpPeakAngleMaxDeg   = 80.0;
input double             InpHoleAngleMaxDeg   = 80.0;
input double             InpZeroTolerance     = 0.05;
input int                InpMinZeroRunBars    = 2;
input int                InpMinWaveBars       = 5;
input double             InpMinWaveAmplitude  = 8.0;
input double             InpMinPeakProminence = 2.0;

input group "04. Marcadores no grafico principal"
input bool               InpShowMarkersOnMainChart = true;
input int                InpMainMarkerOffsetPoints = 0;
input int                InpMarkerSafetyRadiusBars = 1;

input group "05. Diagnostico"
input bool               InpEnableDiagnostics = true;
input bool               InpDiagPrintToJournal = false;
input ENUM_DIAG_MARKER_VIEW_MODE InpDiagMarkerViewMode = DIAG_MARKERS_HOLES_ONLY;
input color              InpDiagColorOk = clrAqua;
input color              InpDiagColorWarn = clrTomato;
input color              InpDiagColorOff = clrSilver;

double g_histogram[];
double g_histogram_color[];
double g_ma[];
double g_wave_apex[];
double g_wave_zero[];
double g_zero_start[];
double g_zero_end[];
double g_upper[];
double g_lower[];
double g_trend_ma[];
int    g_bands_handle = INVALID_HANDLE;
int    g_trend_ma_handle = INVALID_HANDLE;
string g_bands_shortname = "";
bool   g_bands_added_to_main_chart = false;
string g_marker_prefix = "";
string g_indicator_shortname = "";

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

string DiagMarkerViewModeToString(const ENUM_DIAG_MARKER_VIEW_MODE mode)
  {
   switch(mode)
     {
      case DIAG_MARKERS_HOLES_ONLY:
         return "HOLES_ONLY";
      case DIAG_MARKERS_PEAKS_ONLY:
         return "PEAKS_ONLY";
      case DIAG_MARKERS_ZERO_ONLY:
         return "ZERO_ONLY";
      default:
         return "ALL";
     }
  }
//+------------------------------------------------------------------+
//| Calcula angulo interno (graus) no pivô de 3 pontos               |
//+------------------------------------------------------------------+
double ComputeVertexAngleDeg(const double left_value,
                             const double center_value,
                             const double right_value)
  {
   double ux = -1.0;
   double uy = left_value - center_value;
   double vx = 1.0;
   double vy = right_value - center_value;

   double nu = MathSqrt(ux * ux + uy * uy);
   double nv = MathSqrt(vx * vx + vy * vy);
   if(nu <= 0.0 || nv <= 0.0)
      return 180.0;

   double cosine = (ux * vx + uy * vy) / (nu * nv);
   if(cosine > 1.0)
      cosine = 1.0;
   else
      if(cosine < -1.0)
         cosine = -1.0;
   return MathArccos(cosine) * 180.0 / M_PI;
  }
//+------------------------------------------------------------------+
//| Limpa marcadores no grafico principal                            |
//+------------------------------------------------------------------+
void ClearMainChartMarkers()
  {
   int total = ObjectsTotal(ChartID(),0,-1);
   for(int i = total - 1; i >= 0; --i)
     {
      string name = ObjectName(ChartID(),i,0,-1);
      if(StringFind(name,g_marker_prefix) == 0)
         ObjectDelete(ChartID(),name);
     }
  }
//+------------------------------------------------------------------+
//| Desenha bolinha no grafico principal                             |
//+------------------------------------------------------------------+
void DrawMainChartMarker(const string name,
                         const datetime when_time,
                         const double when_price,
                         const color marker_color)
  {
   if(ObjectFind(ChartID(),name) < 0)
     {
      if(!ObjectCreate(ChartID(),name,OBJ_ARROW,0,when_time,when_price))
         return;
     }
   else
      ObjectMove(ChartID(),name,0,when_time,when_price);

   ObjectSetInteger(ChartID(),name,OBJPROP_ARROWCODE,159);
   ObjectSetInteger(ChartID(),name,OBJPROP_WIDTH,3);
   ObjectSetInteger(ChartID(),name,OBJPROP_COLOR,marker_color);
   ObjectSetInteger(ChartID(),name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(ChartID(),name,OBJPROP_SELECTED,false);
   ObjectSetInteger(ChartID(),name,OBJPROP_HIDDEN,true);
  }
//+------------------------------------------------------------------+
//| Reserva indice para marcador com protecao de vizinhanca          |
//+------------------------------------------------------------------+
bool ReserveMarkerSlot(const int index,
                       const int bars_available,
                       const int safety_radius,
                       int &used_slots[])
  {
   if(index < 0 || index >= bars_available)
      return false;

   int radius = safety_radius;
   if(radius < 0)
      radius = 0;

   int left = index - radius;
   if(left < 0)
      left = 0;
   int right = index + radius;
   if(right >= bars_available)
      right = bars_available - 1;

   for(int i = left; i <= right; ++i)
     {
      if(used_slots[i] != 0)
         return false;
     }

   used_slots[index] = 1;
   return true;
  }
//+------------------------------------------------------------------+
//| Atualiza texto com periodo de wave detectado                      |
//+------------------------------------------------------------------+
void UpdateWavePeriodLabel(const datetime &time[],
                           const int bars_available,
                           const int period_bars,
                           const int wave_count)
  {
   string label_name = g_marker_prefix + "period_label";
   int wnd = ChartWindowFind(ChartID(),g_indicator_shortname);
   if(wnd < 0)
      wnd = 0;
   string text = (period_bars > 0
                  ? StringFormat("Wave period: %d bars | waves: %d",period_bars,wave_count)
                  : "Wave period: n/a");

   if(ObjectFind(ChartID(),label_name) >= 0)
     {
      if((ENUM_OBJECT)ObjectGetInteger(ChartID(),label_name,OBJPROP_TYPE) != OBJ_LABEL)
         ObjectDelete(ChartID(),label_name);
     }

   if(ObjectFind(ChartID(),label_name) < 0)
     {
      if(!ObjectCreate(ChartID(),label_name,OBJ_LABEL,wnd,0,0))
         return;
     }

   long width_px = 0;
   long height_px = 0;
   if(!ChartGetInteger(ChartID(),CHART_WIDTH_IN_PIXELS,0,width_px))
      width_px = 800;
   if(!ChartGetInteger(ChartID(),CHART_HEIGHT_IN_PIXELS,wnd,height_px))
      height_px = 180;

   int x = (int)(width_px / 2);
   int y = (int)(height_px / 2);

   ObjectSetString(ChartID(),label_name,OBJPROP_TEXT,text);
   ObjectSetString(ChartID(),label_name,OBJPROP_FONT,"Arial Bold");
   ObjectSetInteger(ChartID(),label_name,OBJPROP_FONTSIZE,18);
   ObjectSetInteger(ChartID(),label_name,OBJPROP_COLOR,(period_bars > 0 ? clrAqua : clrTomato));
   ObjectSetInteger(ChartID(),label_name,OBJPROP_ANCHOR,ANCHOR_CENTER);
   ObjectSetInteger(ChartID(),label_name,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(ChartID(),label_name,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(ChartID(),label_name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(ChartID(),label_name,OBJPROP_SELECTED,false);
   ObjectSetInteger(ChartID(),label_name,OBJPROP_HIDDEN,true);
  }
//| Configura modo de plot do indicador principal                    |
//+------------------------------------------------------------------+
void SetupCompressionPlotMode()
  {
   if(InpCompressionPlotMode == COMPRESSION_AS_LINE)
     {
      PlotIndexSetInteger(0,PLOT_DRAW_TYPE,DRAW_COLOR_LINE);
      PlotIndexSetInteger(0,PLOT_LINE_WIDTH,2);
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
   SetIndexBuffer(3,g_wave_apex,INDICATOR_DATA);
   SetIndexBuffer(4,g_wave_zero,INDICATOR_DATA);
   SetIndexBuffer(5,g_zero_start,INDICATOR_DATA);
   SetIndexBuffer(6,g_zero_end,INDICATOR_DATA);
   ArraySetAsSeries(g_histogram,true);
   ArraySetAsSeries(g_histogram_color,true);
   ArraySetAsSeries(g_ma,true);
   ArraySetAsSeries(g_wave_apex,true);
   ArraySetAsSeries(g_wave_zero,true);
   ArraySetAsSeries(g_zero_start,true);
   ArraySetAsSeries(g_zero_end,true);
   ArraySetAsSeries(g_upper,true);
   ArraySetAsSeries(g_lower,true);
   ArraySetAsSeries(g_trend_ma,true);
   PlotIndexSetDouble(0,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   PlotIndexSetDouble(1,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   PlotIndexSetDouble(2,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   PlotIndexSetDouble(3,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   PlotIndexSetDouble(4,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   PlotIndexSetDouble(5,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   PlotIndexSetInteger(0,PLOT_COLOR_INDEXES,3);
   PlotIndexSetInteger(0,PLOT_LINE_COLOR,0,InpWaveColorTrade);
   PlotIndexSetInteger(0,PLOT_LINE_COLOR,1,InpWaveColorCounterTrend);
   PlotIndexSetInteger(0,PLOT_LINE_COLOR,2,InpWaveColorNoTrend);
   PlotIndexSetInteger(2,PLOT_ARROW,159);
   PlotIndexSetInteger(3,PLOT_ARROW,159);
   PlotIndexSetInteger(4,PLOT_ARROW,159);
   PlotIndexSetInteger(5,PLOT_ARROW,159);
   PlotIndexSetInteger(2,PLOT_LINE_COLOR,0,clrMagenta);
   PlotIndexSetInteger(3,PLOT_LINE_COLOR,0,clrMagenta);
   PlotIndexSetInteger(2,PLOT_LINE_WIDTH,3);
   PlotIndexSetInteger(3,PLOT_LINE_WIDTH,3);
   PlotIndexSetInteger(4,PLOT_LINE_COLOR,0,clrMagenta);
   PlotIndexSetInteger(5,PLOT_LINE_COLOR,0,clrMagenta);
   SetupCompressionPlotMode();
   g_marker_prefix = StringFormat("CompressV25_%I64u_",ChartID());

   g_indicator_shortname = StringFormat("BB Compression (%d, %.2f) + MA(%d) [0..100] + WaveMarks",
                                        InpBandsPeriod,
                                        InpBandsDeviation,
                                        InpMAPeriod);
   IndicatorSetString(INDICATOR_SHORTNAME,g_indicator_shortname);

   if(InpNormalizePeriod < 1)
     {
      Print("InpNormalizePeriod precisa ser >= 1.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpTrendMAPeriod < 1)
     {
      Print("InpTrendMAPeriod precisa ser >= 1.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpTrendSlopeLookback < 1)
     {
      Print("InpTrendSlopeLookback precisa ser >= 1.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpTrendSlopeNeutral < 0.0)
     {
      Print("InpTrendSlopeNeutral precisa ser >= 0.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMAPeriod < 1)
     {
      Print("InpMAPeriod precisa ser >= 1.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpPeakAngleMaxDeg <= 0.0 || InpPeakAngleMaxDeg >= 180.0)
     {
      Print("InpPeakAngleMaxDeg precisa estar entre 0 e 180.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpHoleAngleMaxDeg <= 0.0 || InpHoleAngleMaxDeg >= 180.0)
     {
      Print("InpHoleAngleMaxDeg precisa estar entre 0 e 180.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpZeroTolerance < 0.0)
     {
      Print("InpZeroTolerance precisa ser >= 0.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMinZeroRunBars < 1)
     {
      Print("InpMinZeroRunBars precisa ser >= 1.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMinWaveBars < 2)
     {
      Print("InpMinWaveBars precisa ser >= 2.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMinWaveAmplitude < 0.0)
     {
      Print("InpMinWaveAmplitude precisa ser >= 0.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMinPeakProminence < 0.0)
     {
      Print("InpMinPeakProminence precisa ser >= 0.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMarkerSafetyRadiusBars < 0)
     {
      Print("InpMarkerSafetyRadiusBars precisa ser >= 0.");
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

   g_trend_ma_handle = iMA(_Symbol,
                           PERIOD_CURRENT,
                           InpTrendMAPeriod,
                           0,
                           MODE_EMA,
                           PRICE_CLOSE);
   if(g_trend_ma_handle == INVALID_HANDLE)
     {
      PrintFormat("Falha ao criar EMA de tendencia. Erro=%d",GetLastError());
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
   ClearMainChartMarkers();
   ObjectDelete(ChartID(),g_marker_prefix + "period_label");
   WaveDiagClearOverlay(ChartID(),g_marker_prefix);

   if(g_bands_added_to_main_chart && g_bands_shortname != "")
      ChartIndicatorDelete(ChartID(),0,g_bands_shortname);

   if(g_bands_handle != INVALID_HANDLE)
     {
      IndicatorRelease(g_bands_handle);
      g_bands_handle = INVALID_HANDLE;
     }
   if(g_trend_ma_handle != INVALID_HANDLE)
     {
      IndicatorRelease(g_trend_ma_handle);
      g_trend_ma_handle = INVALID_HANDLE;
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
   if(rates_total <= 0 || g_bands_handle == INVALID_HANDLE || g_trend_ma_handle == INVALID_HANDLE)
      return 0;
   const int max_lookback = MathMax(MathMax(MathMax(InpNormalizePeriod,InpMAPeriod),InpTrendMAPeriod),InpTrendSlopeLookback);
   const bool full_recalc = (prev_calculated <= 0 || prev_calculated > rates_total);
   int delta_bars = (full_recalc ? rates_total : rates_total - prev_calculated);
   if(delta_bars < 0)
      delta_bars = rates_total;

   int recalc_bars = (full_recalc ? rates_total : delta_bars + max_lookback + 8);
   if(recalc_bars < 1)
      recalc_bars = 1;
   if(recalc_bars > rates_total)
      recalc_bars = rates_total;

   if(ArraySize(g_upper) < rates_total)
      ArrayResize(g_upper,rates_total);
   if(ArraySize(g_lower) < rates_total)
      ArrayResize(g_lower,rates_total);
   if(ArraySize(g_trend_ma) < rates_total)
      ArrayResize(g_trend_ma,rates_total);

   int bands_capacity = MathMin(ArraySize(g_upper),ArraySize(g_lower));
   int trend_capacity = ArraySize(g_trend_ma);
   if(bands_capacity <= 0)
      return prev_calculated;
   if(trend_capacity <= 0)
      return prev_calculated;

   int copy_count = recalc_bars + max_lookback + 2;
   if(copy_count > rates_total)
      copy_count = rates_total;
   if(copy_count > bands_capacity)
      copy_count = bands_capacity;
   if(copy_count > trend_capacity)
      copy_count = trend_capacity;
   if(copy_count <= 0)
      return prev_calculated;

   int copied_upper = CopyBuffer(g_bands_handle,1,0,copy_count,g_upper);
   int copied_lower = CopyBuffer(g_bands_handle,2,0,copy_count,g_lower);
   int copied_trend = CopyBuffer(g_trend_ma_handle,0,0,copy_count,g_trend_ma);
   if(copied_upper <= 0 || copied_lower <= 0 || copied_trend <= 0)
      return prev_calculated;

   int bars_available = MathMin(copy_count,MathMin(copied_upper,MathMin(copied_lower,copied_trend)));
   if(bars_available <= 0)
      return prev_calculated;

   WaveDiagStats diag_stats;
   WaveDiagReset(diag_stats,InpEnableDiagnostics);
   diag_stats.bars_available = bars_available;
   diag_stats.marker_view_mode = DiagMarkerViewModeToString(InpDiagMarkerViewMode);
   const bool diag_filter_markers = (InpEnableDiagnostics && InpDiagMarkerViewMode != DIAG_MARKERS_ALL);
   const bool diag_show_holes = (!diag_filter_markers || InpDiagMarkerViewMode == DIAG_MARKERS_HOLES_ONLY);
   const bool diag_show_peaks = (!diag_filter_markers || InpDiagMarkerViewMode == DIAG_MARKERS_PEAKS_ONLY);
   const bool diag_show_zero = (!diag_filter_markers || InpDiagMarkerViewMode == DIAG_MARKERS_ZERO_ONLY);

   int calc_start = recalc_bars - 1;
   if(calc_start >= bars_available)
      calc_start = bars_available - 1;
   if(calc_start < 0)
      return prev_calculated;

   if(full_recalc)
     {
      for(int i = rates_total - 1; i >= bars_available; --i)
        {
         g_histogram[i] = EMPTY_VALUE;
         g_histogram_color[i] = 2.0;
         g_ma[i] = EMPTY_VALUE;
         g_wave_apex[i] = EMPTY_VALUE;
         g_wave_zero[i] = EMPTY_VALUE;
         g_zero_start[i] = EMPTY_VALUE;
         g_zero_end[i] = EMPTY_VALUE;
        }
     }

   if(InpShowMarkersOnMainChart)
      ClearMainChartMarkers();

   int marker_scan_start = bars_available - 1;
   for(int i = marker_scan_start; i >= 0; --i)
     {
      g_wave_apex[i] = EMPTY_VALUE;
      g_wave_zero[i] = EMPTY_VALUE;
      g_zero_start[i] = EMPTY_VALUE;
      g_zero_end[i] = EMPTY_VALUE;
      if(InpShowMarkersOnMainChart)
        {
         string hole_name = StringFormat("%shole_%I64d",g_marker_prefix,(long)time[i]);
         string peak_name = StringFormat("%speak_%I64d",g_marker_prefix,(long)time[i]);
         string zstart_name = StringFormat("%szstart_%I64d",g_marker_prefix,(long)time[i]);
         string zend_name = StringFormat("%szend_%I64d",g_marker_prefix,(long)time[i]);
         ObjectDelete(ChartID(),hole_name);
         ObjectDelete(ChartID(),peak_name);
         ObjectDelete(ChartID(),zstart_name);
         ObjectDelete(ChartID(),zend_name);
        }
     }

   for(int i = calc_start; i >= 0; --i)
     {
      if(g_upper[i] == EMPTY_VALUE || g_lower[i] == EMPTY_VALUE)
        {
         g_histogram[i] = EMPTY_VALUE;
         g_histogram_color[i] = 2.0;
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
      for(int j = i; j <= end_index; ++j)
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
         g_histogram_color[i] = 2.0;
         continue;
        }

      double score = 100.0;
      if(max_distance > 0.0)
         score = 100.0 * (1.0 - (distance / max_distance));
      if(InpInvertCompression)
         score = 100.0 - score;
      g_histogram[i] = ClampScore(score);

      double color_index = 2.0; // sem tendencia
      int trend_ref = i + InpTrendSlopeLookback;
      if(trend_ref < bars_available &&
         g_trend_ma[i] != EMPTY_VALUE &&
         g_trend_ma[trend_ref] != EMPTY_VALUE)
        {
         double trend_slope = g_trend_ma[i] - g_trend_ma[trend_ref];
         if(MathAbs(trend_slope) <= InpTrendSlopeNeutral)
            color_index = 2.0; // sem tendencia
         else
            if(trend_slope > 0.0)
               color_index = (!InpTrendUsePriceFilter || close[i] >= g_trend_ma[i]
                              ? 0.0 // trade (EMA subindo + preco acima)
                              : 1.0); // contra tendencia
            else
               color_index = (!InpTrendUsePriceFilter || close[i] <= g_trend_ma[i]
                              ? 0.0 // trade (EMA caindo + preco abaixo)
                              : 1.0); // contra tendencia
        }
      g_histogram_color[i] = color_index;
     }

   for(int i = calc_start; i >= 0; --i)
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
      for(int j = i; j <= end_index; ++j)
        {
         if(g_histogram[j] == EMPTY_VALUE)
            continue;
         sum += g_histogram[j];
         ++count;
        }

      g_ma[i] = (count > 0 ? sum / count : EMPTY_VALUE);
     }

   if(InpShowWaveMarkers && bars_available >= 5)
     {
      int marker_slots[];
      ArrayResize(marker_slots,bars_available);
      ArrayInitialize(marker_slots,0);

      int run_starts[];
      int run_ends[];
      ArrayResize(run_starts,0);
      ArrayResize(run_ends,0);

      bool in_zero_run = false;
      int run_start = -1;
      int run_end = -1;
      for(int i = bars_available - 2; i >= 1; --i)
        {
         double v = g_histogram[i];
         bool is_zero = (v != EMPTY_VALUE && MathAbs(v) <= InpZeroTolerance);
         if(is_zero)
           {
            if(!in_zero_run)
              {
               in_zero_run = true;
               run_start = i;
              }
            run_end = i;
           }
         else
           {
            if(in_zero_run)
              {
               int rcount = ArraySize(run_starts);
               ArrayResize(run_starts,rcount + 1);
               ArrayResize(run_ends,rcount + 1);
               run_starts[rcount] = run_start;
               run_ends[rcount] = run_end;
               in_zero_run = false;
               run_start = -1;
               run_end = -1;
              }
           }
        }
      if(in_zero_run)
        {
         int rcount = ArraySize(run_starts);
         ArrayResize(run_starts,rcount + 1);
         ArrayResize(run_ends,rcount + 1);
         run_starts[rcount] = run_start;
         run_ends[rcount] = run_end;
        }

      int runs_total = ArraySize(run_starts);
      diag_stats.runs_total = runs_total;
      int selected_runs[];
      ArrayResize(selected_runs,runs_total);
      ArrayInitialize(selected_runs,0);

      int peak_indices[];
      ArrayResize(peak_indices,0);
      int valley_indices[];
      ArrayResize(valley_indices,0);
      int wave_count = 0;
      int peak_spacing_sum = 0;
      int peak_spacing_count = 0;
      int wave_span_sum = 0;
      int wave_span_count = 0;

      int segment_lefts[];
      int segment_rights[];
      int segment_left_run[];
      int segment_right_run[];
      ArrayResize(segment_lefts,0);
      ArrayResize(segment_rights,0);
      ArrayResize(segment_left_run,0);
      ArrayResize(segment_right_run,0);
      const int newest_closed_bar = 2; // evita usar barra 0 em formacao

      if(runs_total == 0)
        {
         int left_no_run = bars_available - 2;
         int right_no_run = newest_closed_bar;
         if(left_no_run >= right_no_run)
           {
            int scount = ArraySize(segment_lefts);
            ArrayResize(segment_lefts,scount + 1);
            ArrayResize(segment_rights,scount + 1);
            ArrayResize(segment_left_run,scount + 1);
            ArrayResize(segment_right_run,scount + 1);
            segment_lefts[scount] = left_no_run;
            segment_rights[scount] = right_no_run;
            segment_left_run[scount] = -1;
            segment_right_run[scount] = -1;
           }
        }
      else
        {
         int left_first = bars_available - 2;
         int right_first = run_starts[0] + 1;
         if(left_first >= right_first)
           {
            int scount = ArraySize(segment_lefts);
            ArrayResize(segment_lefts,scount + 1);
            ArrayResize(segment_rights,scount + 1);
            ArrayResize(segment_left_run,scount + 1);
            ArrayResize(segment_right_run,scount + 1);
            segment_lefts[scount] = left_first;
            segment_rights[scount] = right_first;
            segment_left_run[scount] = -1;
            segment_right_run[scount] = 0;
           }

         for(int r = 1; r < runs_total; ++r)
           {
            int between_left = run_ends[r - 1] - 1;
            int between_right = run_starts[r] + 1;
            if(between_left < between_right)
               continue;
            int scount = ArraySize(segment_lefts);
            ArrayResize(segment_lefts,scount + 1);
            ArrayResize(segment_rights,scount + 1);
            ArrayResize(segment_left_run,scount + 1);
            ArrayResize(segment_right_run,scount + 1);
            segment_lefts[scount] = between_left;
            segment_rights[scount] = between_right;
            segment_left_run[scount] = r - 1;
            segment_right_run[scount] = r;
           }

         int left_last = run_ends[runs_total - 1] - 1;
         int right_last = newest_closed_bar;
         if(left_last >= right_last)
           {
            int scount = ArraySize(segment_lefts);
            ArrayResize(segment_lefts,scount + 1);
            ArrayResize(segment_rights,scount + 1);
            ArrayResize(segment_left_run,scount + 1);
            ArrayResize(segment_right_run,scount + 1);
            segment_lefts[scount] = left_last;
            segment_rights[scount] = right_last;
            segment_left_run[scount] = runs_total - 1;
            segment_right_run[scount] = -1;
           }
        }

      int segments_total = ArraySize(segment_lefts);
      diag_stats.segments_total = segments_total;
      for(int s = 0; s < segments_total; ++s)
        {
         int segment_left = segment_lefts[s];
         int segment_right = segment_rights[s];
         if(segment_left < segment_right)
            continue;
         int segment_bars = segment_left - segment_right + 1;
         if(segment_bars < InpMinWaveBars)
           {
            ++diag_stats.rejected_short_segment;
            WaveDiagSetLastEvent(diag_stats,
                                 StringFormat("reject short seg[%d] bars=%d",s,segment_bars));
            continue;
           }

         double segment_min = DBL_MAX;
         double segment_max = -DBL_MAX;
         int segment_max_index = -1;
         for(int i = segment_left; i >= segment_right; --i)
           {
            double value = g_histogram[i];
            if(value == EMPTY_VALUE)
               continue;
            if(value < segment_min)
               segment_min = value;
            if(value > segment_max)
              {
               segment_max = value;
               segment_max_index = i;
              }
           }
         if(segment_max_index < 0 || segment_min == DBL_MAX || segment_max == -DBL_MAX)
            continue;
         if((segment_max - segment_min) < InpMinWaveAmplitude)
           {
            ++diag_stats.rejected_low_amplitude;
            WaveDiagSetLastEvent(diag_stats,
                                 StringFormat("reject amp seg[%d] amp=%.2f",s,(segment_max - segment_min)));
            continue;
           }

         int best_peak_index = -1;
         double best_peak_value = -DBL_MAX;
         for(int i = segment_left; i >= segment_right; --i)
           {
            if(i <= 1 || i >= bars_available - 1)
               continue;
            double left_value = g_histogram[i + 1];
            double center_value = g_histogram[i];
            double right_value = g_histogram[i - 1];
            if(left_value == EMPTY_VALUE || center_value == EMPTY_VALUE || right_value == EMPTY_VALUE)
               continue;
            if(g_ma[i] == EMPTY_VALUE || center_value <= g_ma[i])
               continue;
            if(!(center_value > left_value && center_value > right_value))
               continue;

            double peak_angle = ComputeVertexAngleDeg(left_value,center_value,right_value);
            if(peak_angle > InpPeakAngleMaxDeg)
               continue;
            if((center_value - MathMax(left_value,right_value)) < InpMinPeakProminence)
               continue;

            if(center_value > best_peak_value)
              {
               best_peak_value = center_value;
               best_peak_index = i;
              }
           }

         if(best_peak_index < 0 && segment_max_index > 1 && segment_max_index < bars_available - 1)
           {
            double left_value = g_histogram[segment_max_index + 1];
            double center_value = g_histogram[segment_max_index];
            double right_value = g_histogram[segment_max_index - 1];
            if(left_value != EMPTY_VALUE && center_value != EMPTY_VALUE && right_value != EMPTY_VALUE)
              {
               double peak_angle = ComputeVertexAngleDeg(left_value,center_value,right_value);
               if(peak_angle <= InpPeakAngleMaxDeg &&
                  (center_value - MathMax(left_value,right_value)) >= (InpMinPeakProminence * 0.5))
                 {
                  best_peak_index = segment_max_index;
                  best_peak_value = center_value;
                 }
              }
           }

         if(best_peak_index >= 0)
           {
            ++wave_count;
            ++diag_stats.waves_valid;
            wave_span_sum += segment_bars;
            ++wave_span_count;

            bool peak_reserved = ReserveMarkerSlot(best_peak_index,
                                                   bars_available,
                                                   InpMarkerSafetyRadiusBars,
                                                   marker_slots);
            if(!peak_reserved)
               WaveDiagCountSlotConflict(diag_stats,"peak",best_peak_index);

            if(InpShowPeakMarkers && peak_reserved && diag_show_peaks)
              {
               g_wave_zero[best_peak_index] = best_peak_value;
               ++diag_stats.peaks_marked;
               WaveDiagSetLastEvent(diag_stats,
                                    StringFormat("wave ok seg[%d] peak=%d val=%.2f",
                                                 s,best_peak_index,best_peak_value));
              }

            if(InpShowMarkersOnMainChart && InpShowPeakMarkers && peak_reserved && diag_show_peaks)
              {
               double peak_price = high[best_peak_index];
               if(InpMainMarkerOffsetPoints > 0)
                  peak_price += InpMainMarkerOffsetPoints * _Point;
               string peak_name = StringFormat("%speak_%I64d",g_marker_prefix,(long)time[best_peak_index]);
               DrawMainChartMarker(peak_name,time[best_peak_index],peak_price,clrMagenta);
              }

            int pcount = ArraySize(peak_indices);
            ArrayResize(peak_indices,pcount + 1);
            peak_indices[pcount] = best_peak_index;

            if(pcount > 0)
              {
               peak_spacing_sum += (peak_indices[pcount - 1] - best_peak_index);
               ++peak_spacing_count;
              }

            int left_run_idx = segment_left_run[s];
            int right_run_idx = segment_right_run[s];
            if(left_run_idx >= 0 && left_run_idx < runs_total)
               selected_runs[left_run_idx] = 1;
            if(right_run_idx >= 0 && right_run_idx < runs_total)
               selected_runs[right_run_idx] = 1;

            int valley_index = -1;
            double valley_value = DBL_MAX;
            for(int k = segment_left; k >= segment_right; --k)
              {
               if(k == best_peak_index)
                  continue;
               double value_k = g_histogram[k];
               if(value_k == EMPTY_VALUE)
                  continue;
               if(MathAbs(value_k) <= InpZeroTolerance)
                  continue; // buraco deve ficar dentro da wave, nao no zero
               if(value_k < valley_value)
                 {
                  valley_value = value_k;
                  valley_index = k;
                 }
              }

            if(valley_index >= 0 && valley_index > 0 && valley_index < bars_available - 1)
              {
               double left_valley = g_histogram[valley_index + 1];
               double center_valley = g_histogram[valley_index];
               double right_valley = g_histogram[valley_index - 1];
              if(left_valley != EMPTY_VALUE && center_valley != EMPTY_VALUE && right_valley != EMPTY_VALUE)
                {
                  double hole_angle = ComputeVertexAngleDeg(left_valley,center_valley,right_valley);
                  if(hole_angle <= InpHoleAngleMaxDeg &&
                     (MathMin(left_valley,right_valley) - center_valley) >= InpMinPeakProminence)
                    {
                     int vcount = ArraySize(valley_indices);
                     ArrayResize(valley_indices,vcount + 1);
                     valley_indices[vcount] = valley_index;
                    }
                }
              }
           }
         else
           {
            ++diag_stats.rejected_no_peak;
            WaveDiagSetLastEvent(diag_stats,StringFormat("reject no_peak seg[%d]",s));
           }
        }

      int valleys_total = ArraySize(valley_indices);
      for(int v = 0; v < valleys_total; ++v)
        {
         int valley_index = valley_indices[v];
         if(valley_index < 0 || valley_index >= bars_available)
            continue;
         double valley_value = g_histogram[valley_index];
         if(valley_value == EMPTY_VALUE)
            continue;

         bool valley_reserved = ReserveMarkerSlot(valley_index,
                                                  bars_available,
                                                  InpMarkerSafetyRadiusBars,
                                                  marker_slots);
         if(!valley_reserved)
           {
            WaveDiagCountSlotConflict(diag_stats,"hole",valley_index);
            continue;
           }

         if(diag_show_holes)
           {
            g_wave_apex[valley_index] = valley_value;
            ++diag_stats.holes_marked;
            WaveDiagSetLastEvent(diag_stats,
                                 StringFormat("hole idx=%d val=%.2f",valley_index,valley_value));
           }

         if(InpShowMarkersOnMainChart && diag_show_holes)
           {
            double marker_price = low[valley_index];
            if(InpMainMarkerOffsetPoints > 0)
               marker_price -= InpMainMarkerOffsetPoints * _Point;
            string marker_name = StringFormat("%shole_%I64d",g_marker_prefix,(long)time[valley_index]);
            DrawMainChartMarker(marker_name,time[valley_index],marker_price,clrMagenta);
           }
        }

      for(int r = 0; r < runs_total; ++r)
        {
         if(selected_runs[r] == 0)
            continue;
         ++diag_stats.runs_selected;

         int run_len = MathAbs(run_starts[r] - run_ends[r]) + 1;
         if(run_len < InpMinZeroRunBars)
            continue;

         int zstart = run_starts[r];
         int zend = run_ends[r];
         if(zstart >= 0 && zstart < bars_available &&
            ReserveMarkerSlot(zstart,bars_available,InpMarkerSafetyRadiusBars,marker_slots))
           {
            if(diag_show_zero)
              {
               g_zero_start[zstart] = 0.0;
               ++diag_stats.zero_marked;
               WaveDiagSetLastEvent(diag_stats,
                                    StringFormat("zero_start idx=%d run=%d",zstart,r));
               if(InpShowMarkersOnMainChart)
                 {
                  double marker_price = close[zstart];
                  string marker_name = StringFormat("%szstart_%I64d",g_marker_prefix,(long)time[zstart]);
                  DrawMainChartMarker(marker_name,time[zstart],marker_price,clrMagenta);
                 }
              }
           }
         else
            if(zstart >= 0 && zstart < bars_available)
               WaveDiagCountSlotConflict(diag_stats,"zstart",zstart);
         if(zend >= 0 && zend < bars_available &&
            ReserveMarkerSlot(zend,bars_available,InpMarkerSafetyRadiusBars,marker_slots))
           {
            if(diag_show_zero)
              {
               g_zero_end[zend] = 0.0;
               ++diag_stats.zero_marked;
               WaveDiagSetLastEvent(diag_stats,
                                    StringFormat("zero_end idx=%d run=%d",zend,r));
               if(InpShowMarkersOnMainChart)
                 {
                  double marker_price = close[zend];
                  string marker_name = StringFormat("%szend_%I64d",g_marker_prefix,(long)time[zend]);
                  DrawMainChartMarker(marker_name,time[zend],marker_price,clrMagenta);
                 }
              }
           }
         else
            if(zend >= 0 && zend < bars_available)
               WaveDiagCountSlotConflict(diag_stats,"zend",zend);
        }

      int detected_period = 0;
      if(peak_spacing_count > 0)
         detected_period = (int)MathRound((double)peak_spacing_sum / (double)peak_spacing_count);
      else
         if(wave_span_count > 0)
            detected_period = (int)MathRound((double)wave_span_sum / (double)wave_span_count);

      UpdateWavePeriodLabel(time,bars_available,detected_period,wave_count);
     }
   else
     {
      ObjectDelete(ChartID(),g_marker_prefix + "period_label");
      WaveDiagSetLastEvent(diag_stats,"wave markers disabled or bars_available < 5");
     }

   if(InpEnableDiagnostics)
     {
      WaveDiagRenderOverlay(ChartID(),
                            g_marker_prefix,
                            g_indicator_shortname,
                            diag_stats,
                            InpDiagColorOk,
                            InpDiagColorWarn,
                            InpDiagColorOff);
      if(InpDiagPrintToJournal && (full_recalc || delta_bars > 0))
         PrintFormat("Diag waves=%d segments=%d runs=%d selected=%d peaks=%d holes=%d zero=%d reject(short=%d amp=%d no_peak=%d slot=%d) event=%s",
                     diag_stats.waves_valid,
                     diag_stats.segments_total,
                     diag_stats.runs_total,
                     diag_stats.runs_selected,
                     diag_stats.peaks_marked,
                     diag_stats.holes_marked,
                     diag_stats.zero_marked,
                     diag_stats.rejected_short_segment,
                     diag_stats.rejected_low_amplitude,
                     diag_stats.rejected_no_peak,
                     diag_stats.rejected_slot_conflict,
                     diag_stats.last_event);
     }
   else
      WaveDiagClearOverlay(ChartID(),g_marker_prefix);
//--- return value of prev_calculated for next call
   return(rates_total);
  }
//+------------------------------------------------------------------+
