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
#property indicator_buffers 3
#property indicator_plots   3
#property indicator_label1  "BB Compression"
#property indicator_type1   DRAW_HISTOGRAM
#property indicator_color1  clrDodgerBlue
#property indicator_width1  2
#property indicator_label2  "Compression MA"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrOrange
#property indicator_width2  1
#property indicator_label3  "Bolinhas Magenta (Destaque)"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrFuchsia
#property indicator_width3  5

enum ENUM_COMPRESSION_PLOT_MODE
  {
   COMPRESSION_AS_HISTOGRAM = 0,
   COMPRESSION_AS_LINE      = 1
  };

input group "01. Bollinger e Compression"
input int                InpBandsPeriod       = 7;
input int                InpBandsShift        = 0;
input double             InpBandsDeviation    = 5;
input ENUM_APPLIED_PRICE InpBandsAppliedPrice = PRICE_CLOSE;
input bool               InpShowBandsOnMainChart = true;
input int                InpNormalizePeriod   = 3;
input ENUM_COMPRESSION_PLOT_MODE InpCompressionPlotMode = COMPRESSION_AS_HISTOGRAM;
input bool               InpUseMALine         = false;
input int                InpMAPeriod          = 14;
input bool               InpInvertCompression = false;

input group "02. Marcacao de Buracos e Zero"
input bool               InpShowHoleMarkers   = true;
input bool               InpShowShelfTopMarkers = true; // Marca topos/prateleiras locais
input bool               InpShowZeroEdgeMarkers = true;
input double             InpZeroTolerance     = 0.05;
input double             InpZeroZoneBand      = 5.0;
input double             InpZeroExitBandExtra = 1.0; // Histerese para evitar repeticao de marcas no zero
input int                InpMinZeroRunBars    = 4;   // Minimo de barras para marcar inicio/fim do zero
input double             InpMinHoleStrength   = 1.0; // Forca minima do buraco para evitar sequencias
input int                InpHoleRelocationRadius = 2; // Busca ponto alternativo no buraco
input int                InpMinMarkerGapBars  = 5; // Distancia minima entre bolinhas
input bool               InpShowMarkersOnMainChart = true;
input int                InpMainMarkerOffsetPoints = 0;

double g_histogram[];
double g_ma[];
double g_marks[];
double g_upper[];
double g_lower[];
int    g_bands_handle = INVALID_HANDLE;
string g_bands_shortname = "";
bool   g_bands_added_to_main_chart = false;
string g_marker_prefix = "";

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

bool IsSlotFree(const int index,
                const int bars_available,
                const int safety_radius,
                const int &used[])
  {
   if(index < 1 || index > bars_available - 2)
      return false;

   for(int k = MathMax(1,index - safety_radius); k <= MathMin(bars_available - 2,index + safety_radius); ++k)
     {
      if(used[k] != 0)
         return false;
     }
   return true;
  }

int DistanceToNearestUsed(const int index,
                          const int bars_available,
                          const int &used[])
  {
   int best = bars_available;
   for(int k = 1; k <= bars_available - 2; ++k)
     {
      if(used[k] == 0)
         continue;
      int d = MathAbs(index - k);
      if(d < best)
         best = d;
     }
   return best;
  }

double TurnStrengthAt(const int index,
                      const int bars_available,
                      const double &hist[])
  {
   if(index < 1 || index > bars_available - 2)
      return 0.0;

   const double center = hist[index];
   const double left = hist[index + 1];
   const double right = hist[index - 1];
   if(left == EMPTY_VALUE || right == EMPTY_VALUE)
      return 0.0;
   if(center == EMPTY_VALUE)
      return 0.0;

   return (MathAbs(center - left) + MathAbs(center - right));
  }

bool IsHoleCandidateAt(const int index,
                       const int bars_available,
                       const double &hist[],
                       const double zero_band)
  {
   if(index < 2 || index > bars_available - 2)
      return false;

   const double center = hist[index];
   const double left = hist[index + 1];
   const double right = hist[index - 1];
   if(center == EMPTY_VALUE || left == EMPTY_VALUE || right == EMPTY_VALUE)
      return false;
   if(MathAbs(center) <= zero_band)
      return false;
   // Perto de zero, mantem apenas regra especial de inicio/fim.
   if(MathAbs(left) <= zero_band || MathAbs(right) <= zero_band)
      return false;

   const double eps = MathMax(0.05,InpZeroTolerance);
   const int shoulder_radius = MathMax(2,InpHoleRelocationRadius + 1);

   const int left_from = index + 1;
   const int left_to = MathMin(bars_available - 2,index + shoulder_radius);
   const int right_from = MathMax(2,index - shoulder_radius);
   const int right_to = index - 1;
   if(left_from > left_to || right_from > right_to)
      return false;

   double left_peak = -DBL_MAX;
   double right_peak = -DBL_MAX;
   bool has_left_peak = false;
   bool has_right_peak = false;

   for(int k = left_from; k <= left_to; ++k)
     {
      const double v = hist[k];
      if(v == EMPTY_VALUE)
         continue;
      if(v > left_peak)
         left_peak = v;
      has_left_peak = true;
     }

   for(int k = right_from; k <= right_to; ++k)
     {
      const double v = hist[k];
      if(v == EMPTY_VALUE)
         continue;
      if(v > right_peak)
         right_peak = v;
      has_right_peak = true;
     }

   if(!has_left_peak || !has_right_peak)
      return false;

   if(MathAbs(left_peak) <= zero_band || MathAbs(right_peak) <= zero_band)
      return false;

   const double depth_left = left_peak - center;
   const double depth_right = right_peak - center;
   const double depth_sum = MathMax(0.0,depth_left) + MathMax(0.0,depth_right);

   // Captura:
   // 1) V classico (dois lados subindo a partir do centro)
   // 2) V entortado (um lado forte e outro lado menor, mas ainda interno)
   const double min_side_depth = MathMax(eps,InpMinHoleStrength * 0.35);
   const double min_total_depth = MathMax(2.0 * eps,InpMinHoleStrength);
   const bool classic_v = (depth_left >= min_side_depth &&
                           depth_right >= min_side_depth &&
                           depth_sum >= min_total_depth);
   const bool bent_v = ((depth_left >= min_total_depth && depth_right >= min_side_depth * 0.5) ||
                        (depth_right >= min_total_depth && depth_left >= min_side_depth * 0.5));

   if(!(classic_v || bent_v))
     {
      // Fallback leve: V local simples para evitar sumir com todas as bolinhas.
      const double fallback_eps = MathMax(0.02,InpZeroTolerance * 0.5);
      const bool simple_v = (center <= left - fallback_eps && center <= right - fallback_eps);
      const double simple_depth = MathMin(left - center,right - center);
      const double min_simple_depth = MathMax(0.08,InpMinHoleStrength * 0.08);
      if(!(simple_v && simple_depth >= min_simple_depth))
         return false;
     }

   // Centro precisa ser o fundo local no entorno dos ombros.
   double neigh_min = DBL_MAX;
   for(int k = MathMax(2,index - shoulder_radius); k <= MathMin(bars_available - 2,index + shoulder_radius); ++k)
     {
      if(k == index)
         continue;
      double v = hist[k];
      if(v == EMPTY_VALUE)
         continue;
      if(v < neigh_min)
         neigh_min = v;
     }
   if(neigh_min < DBL_MAX && center > neigh_min + eps * 1.5)
      return false;

   return true;
  }

bool IsShelfTopCandidateAt(const int index,
                           const int bars_available,
                           const double &hist[],
                           const double zero_band)
  {
   if(index < 2 || index > bars_available - 2)
      return false;

   const double center = hist[index];
   const double left = hist[index + 1];
   const double right = hist[index - 1];
   if(center == EMPTY_VALUE || left == EMPTY_VALUE || right == EMPTY_VALUE)
      return false;
   if(MathAbs(center) <= zero_band)
      return false;
   if(MathAbs(left) <= zero_band || MathAbs(right) <= zero_band)
      return false;

   const double eps = MathMax(0.05,InpZeroTolerance);
   const int shoulder_radius = MathMax(2,InpHoleRelocationRadius + 1);

   const int left_from = index + 1;
   const int left_to = MathMin(bars_available - 2,index + shoulder_radius);
   const int right_from = MathMax(2,index - shoulder_radius);
   const int right_to = index - 1;
   if(left_from > left_to || right_from > right_to)
      return false;

   double left_valley = DBL_MAX;
   double right_valley = DBL_MAX;
   bool has_left_valley = false;
   bool has_right_valley = false;

   for(int k = left_from; k <= left_to; ++k)
     {
      const double v = hist[k];
      if(v == EMPTY_VALUE)
         continue;
      if(v < left_valley)
         left_valley = v;
      has_left_valley = true;
     }
   for(int k = right_from; k <= right_to; ++k)
     {
      const double v = hist[k];
      if(v == EMPTY_VALUE)
         continue;
      if(v < right_valley)
         right_valley = v;
      has_right_valley = true;
     }

   if(!has_left_valley || !has_right_valley)
      return false;

   const double rise_left = center - left_valley;
   const double rise_right = center - right_valley;
   const double rise_sum = MathMax(0.0,rise_left) + MathMax(0.0,rise_right);

   const double min_side_rise = MathMax(eps,InpMinHoleStrength * 0.35);
   const double min_total_rise = MathMax(2.0 * eps,InpMinHoleStrength);
   const bool classic_top = (rise_left >= min_side_rise &&
                             rise_right >= min_side_rise &&
                             rise_sum >= min_total_rise);
   const bool bent_top = ((rise_left >= min_total_rise && rise_right >= min_side_rise * 0.5) ||
                          (rise_right >= min_total_rise && rise_left >= min_side_rise * 0.5));
   if(!(classic_top || bent_top))
      return false;

   // Centro precisa ser topo local no entorno curto, com tolerancia para "prateleira".
   double neigh_max = -DBL_MAX;
   for(int k = MathMax(2,index - shoulder_radius); k <= MathMin(bars_available - 2,index + shoulder_radius); ++k)
     {
      if(k == index)
         continue;
      const double v = hist[k];
      if(v == EMPTY_VALUE)
         continue;
      if(v > neigh_max)
         neigh_max = v;
     }
   if(neigh_max > -DBL_MAX && center < neigh_max - eps * 1.5)
      return false;

   return true;
  }

int FindBestHoleCenter(const int index,
                       const int bars_available,
                       const double &hist[],
                       const double zero_band,
                       const int radius)
  {
   const int r = MathMax(0,radius);
   const int left_i = MathMax(2,index - r);
   const int right_i = MathMin(bars_available - 2,index + r);
   const double eps = MathMax(0.05,InpZeroTolerance);

   int best_idx = -1;
   double best_val = DBL_MAX;
   double best_strength = -DBL_MAX;

   for(int i = left_i; i <= right_i; ++i)
     {
      if(!IsHoleCandidateAt(i,bars_available,hist,zero_band))
         continue;

      const double center = hist[i];
      const double left = hist[i + 1];
      const double right = hist[i - 1];
      const double strength = (MathAbs(left - center) + MathAbs(right - center));

      if(center < best_val - eps)
        {
         best_val = center;
         best_strength = strength;
         best_idx = i;
        }
      else if(MathAbs(center - best_val) <= eps && strength > best_strength + eps)
        {
         best_strength = strength;
         best_idx = i;
        }
     }

   if(best_idx > 0)
      return best_idx;
   return index;
  }

int FindBestShelfTopCenter(const int index,
                           const int bars_available,
                           const double &hist[],
                           const double zero_band,
                           const int radius)
  {
   const int r = MathMax(0,radius);
   const int left_i = MathMax(2,index - r);
   const int right_i = MathMin(bars_available - 2,index + r);
   const double eps = MathMax(0.05,InpZeroTolerance);

   int best_idx = -1;
   double best_val = -DBL_MAX;
   double best_strength = -DBL_MAX;

   for(int i = left_i; i <= right_i; ++i)
     {
      if(!IsShelfTopCandidateAt(i,bars_available,hist,zero_band))
         continue;

      const double center = hist[i];
      const double left = hist[i + 1];
      const double right = hist[i - 1];
      const double strength = (MathAbs(center - left) + MathAbs(center - right));

      if(center > best_val + eps)
        {
         best_val = center;
         best_strength = strength;
         best_idx = i;
        }
      else if(MathAbs(center - best_val) <= eps && strength > best_strength + eps)
        {
         best_strength = strength;
         best_idx = i;
        }
     }

   if(best_idx > 0)
      return best_idx;
   return index;
  }

bool IsLooseHoleCandidateAt(const int index,
                            const int bars_available,
                            const double &hist[])
  {
   if(index < 2 || index > bars_available - 2)
      return false;

   const double c = hist[index];
   const double l = hist[index + 1];
   const double r = hist[index - 1];
   if(c == EMPTY_VALUE || l == EMPTY_VALUE || r == EMPTY_VALUE)
      return false;

   const double eps = MathMax(0.01,InpZeroTolerance * 0.25);
   const bool simple_v = (c <= l + eps && c <= r + eps);
   const double turn = (l - c) + (r - c);
   const double min_turn = MathMax(0.05,InpMinHoleStrength * 0.06);
   return (simple_v && turn >= min_turn);
  }

int FindBestLooseHoleCenter(const int index,
                            const int bars_available,
                            const double &hist[],
                            const int radius)
  {
   const int r = MathMax(0,radius);
   const int left_i = MathMax(2,index - r);
   const int right_i = MathMin(bars_available - 2,index + r);

   int best_idx = -1;
   double best_val = DBL_MAX;
   for(int i = left_i; i <= right_i; ++i)
     {
      if(!IsLooseHoleCandidateAt(i,bars_available,hist))
         continue;
      if(hist[i] < best_val)
        {
         best_val = hist[i];
         best_idx = i;
        }
     }

   if(best_idx > 0)
      return best_idx;
   return index;
  }

int ClassifyPendulumPolarity(const int index,
                             const int bars_available,
                             const double &hist[])
  {
   if(index < 1 || index > bars_available - 2)
      return 0;

   const double center = hist[index];
   const double left = hist[index + 1];
   const double right = hist[index - 1];
   if(center == EMPTY_VALUE || left == EMPTY_VALUE || right == EMPTY_VALUE)
      return 0;

   const double eps = MathMax(0.05,InpZeroTolerance);

   // Topo local no pendulo -> desenha em cima do preco.
   if(center >= left + eps && center >= right + eps)
      return +1;

   // Fundo local no pendulo -> desenha embaixo do preco.
   if(center <= left - eps && center <= right - eps)
      return -1;

   // Fase: quando o sinal esta subindo, trata como fundo (baixo do preco).
   // Quando esta descendo, trata como topo (cima do preco).
   const double phase_slope = right - left;
   if(phase_slope > eps)
      return -1;
   if(phase_slope < -eps)
      return +1;

   return 0;
  }


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

void DrawMainChartMarker(const string name,
                         const datetime when_time,
                         const double when_price)
  {
   if(ObjectFind(ChartID(),name) < 0)
     {
      if(!ObjectCreate(ChartID(),name,OBJ_ARROW,0,when_time,when_price))
         return;
     }
   else
      ObjectMove(ChartID(),name,0,when_time,when_price);

   ObjectSetInteger(ChartID(),name,OBJPROP_ARROWCODE,159);
   ObjectSetInteger(ChartID(),name,OBJPROP_WIDTH,5);
   ObjectSetInteger(ChartID(),name,OBJPROP_COLOR,clrFuchsia);
   ObjectSetInteger(ChartID(),name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(ChartID(),name,OBJPROP_SELECTED,false);
   ObjectSetInteger(ChartID(),name,OBJPROP_HIDDEN,true);
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

   if(InpUseMALine)
     {
      PlotIndexSetInteger(1,PLOT_DRAW_TYPE,DRAW_LINE);
      PlotIndexSetInteger(1,PLOT_LINE_WIDTH,1);
     }
   else
      PlotIndexSetInteger(1,PLOT_DRAW_TYPE,DRAW_NONE);
  }
//+------------------------------------------------------------------+
//| Custom indicator initialization function                         |
//+------------------------------------------------------------------+
int OnInit()
  {
//--- indicator buffers mapping
   SetIndexBuffer(0,g_histogram,INDICATOR_DATA);
   SetIndexBuffer(1,g_ma,INDICATOR_DATA);
   SetIndexBuffer(2,g_marks,INDICATOR_DATA);
   ArraySetAsSeries(g_histogram,true);
   ArraySetAsSeries(g_ma,true);
   ArraySetAsSeries(g_marks,true);
   PlotIndexSetDouble(0,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   PlotIndexSetDouble(1,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   PlotIndexSetDouble(2,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   PlotIndexSetInteger(2,PLOT_ARROW,159);
   SetupCompressionPlotMode();
   g_marker_prefix = StringFormat("CompressV215u8_%I64u_",ChartID());

   string ma_info = (InpUseMALine ? StringFormat(" + MA(%d)",InpMAPeriod) : "");
   IndicatorSetString(INDICATOR_SHORTNAME,
                      StringFormat("COMPRESS BOLINHAS DESTAQUE | BB Compression (%d, %.2f)%s + WaveMarks [0..100]",
                                   InpBandsPeriod,
                                   InpBandsDeviation,
                                   ma_info));

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
   if(InpZeroTolerance < 0.0)
     {
      Print("InpZeroTolerance precisa ser >= 0.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpZeroZoneBand < 0.0)
     {
      Print("InpZeroZoneBand precisa ser >= 0.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpZeroExitBandExtra < 0.0)
     {
      Print("InpZeroExitBandExtra precisa ser >= 0.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMinZeroRunBars < 1)
     {
      Print("InpMinZeroRunBars precisa ser >= 1.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMinHoleStrength < 0.0)
     {
      Print("InpMinHoleStrength precisa ser >= 0.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpHoleRelocationRadius < 0)
     {
      Print("InpHoleRelocationRadius precisa ser >= 0.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMinMarkerGapBars < 1)
     {
      Print("InpMinMarkerGapBars precisa ser >= 1.");
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
   ClearMainChartMarkers();

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

   const bool full_recalc = (prev_calculated <= 0 || prev_calculated > rates_total);
   // Sem recálculo desnecessário: se não abriu barra nova, não recalcula nada.
   if(!full_recalc && rates_total == prev_calculated)
      return(prev_calculated);

   // Em barra nova, recalcula apenas a faixa recente estritamente necessária.
   int recalc_span = MathMax(InpNormalizePeriod,InpMAPeriod) + InpHoleRelocationRadius + 3;
   int calc_start = (full_recalc ? bars_available - 1 : MathMin(bars_available - 1, recalc_span));
   if(calc_start < 0)
      return prev_calculated;

   // Limpa barras sem dados suficientes
   for(int i = rates_total - 1; i >= bars_available; i--)
     {
      g_histogram[i] = EMPTY_VALUE;
      g_ma[i] = EMPTY_VALUE;
      g_marks[i] = EMPTY_VALUE;
     }
 
   // Calculo incremental do histograma
   for(int i = calc_start; i >= 0; i--)
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

   if(InpUseMALine)
     {
      // A media pode adicionar atraso visual, como qualquer smoothing.
      // Mantido incremental para evitar recálculo completo por tick.
      for(int i = calc_start; i >= 0; i--)
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
     }
   else
     {
      for(int i = calc_start; i >= 0; --i)
         g_ma[i] = EMPTY_VALUE;
     }

   // Marcacoes sem repaint historico:
   // - full_recalc: calcula historico inteiro uma vez.
   // - incremental: recalcula somente a barra 2 (barra fechada mais recente).
   // Regra de estabilidade: nunca desenhar bolinha em barra 0/1.
   const int first_stable_mark_bar = 2;
   int mark_calc_start = (full_recalc ? (bars_available - 2) : first_stable_mark_bar);
   if(mark_calc_start < first_stable_mark_bar)
      mark_calc_start = first_stable_mark_bar;
   for(int i = mark_calc_start; i >= first_stable_mark_bar; --i)
      g_marks[i] = EMPTY_VALUE;
   if(bars_available > 0)
      g_marks[0] = EMPTY_VALUE;
   if(bars_available > 1)
      g_marks[1] = EMPTY_VALUE;

   // Marcacao: 1 bolinha por buraco (fundo), sem duplicar.
   // Processa apenas barras estaveis [bars_available-2 .. 2].
   int marker_used[];
   ArrayResize(marker_used,bars_available);
   ArrayInitialize(marker_used,0);
   // Distancia minima entre bolinhas: configuravel.
   // Ex.: gap=5 -> |i-j| >= 5.
   const int marker_safety_radius = MathMax(0,InpMinMarkerGapBars - 1);
   const double zero_band = MathMax(InpZeroTolerance,InpZeroZoneBand);
   const double zero_exit_band = zero_band + InpZeroExitBandExtra;

   // Preserva apenas marcacoes fora da janela recalculada.
   for(int k = mark_calc_start + 1; k <= bars_available - 2; ++k)
     {
      if(g_marks[k] != EMPTY_VALUE)
         marker_used[k] = 1;
     }

   // Regra solicitada: todas as bolinhas devem ficar no buraco (fundo).
   // Portanto, desativa marcacao por topo/prateleira e borda de zero.
   // Mantem buraco sempre ativo para evitar "sumir tudo" por input desligado.
   const bool use_zero_edge_markers = false;
   const bool use_hole_only_markers = true;

   bool in_zero_run = false;
   int zero_run_first = -1;
   int zero_run_last  = -1;
   if(mark_calc_start + 1 <= bars_available - 2 && mark_calc_start + 1 >= first_stable_mark_bar)
     {
      double b = g_histogram[mark_calc_start + 1];
      if(b != EMPTY_VALUE && MathAbs(b) <= zero_exit_band)
        {
         in_zero_run = true;
         zero_run_first = mark_calc_start + 1;
         zero_run_last = mark_calc_start + 1;
        }
     }

   for(int i = mark_calc_start; i >= first_stable_mark_bar; i--)
     {
      double center = g_histogram[i];
      if(center == EMPTY_VALUE)
        {
         in_zero_run = false;
         continue;
        }

      bool is_zero = (MathAbs(center) <= zero_band);
      if(use_zero_edge_markers)
        {
         bool is_inside_zero_run = (MathAbs(center) <= zero_exit_band);
         if(is_inside_zero_run)
           {
            if(!in_zero_run)
              {
               in_zero_run = true;
               zero_run_first = i;
              }
            if(zero_run_first < 0)
               zero_run_first = i;
            zero_run_last = i;
           }
         else if(in_zero_run)
           {
            // Zero especial: marca primeira e ultima barra do trecho zerado.
            int true_zero_first = zero_run_first;
            while(true_zero_first + 1 <= bars_available - 2)
              {
               double b0 = g_histogram[true_zero_first + 1];
               if(b0 == EMPTY_VALUE || MathAbs(b0) > zero_band)
                  break;
               true_zero_first++;
              }

            int true_zero_last = zero_run_last;
            while(true_zero_last - 1 >= first_stable_mark_bar)
              {
               double b1 = g_histogram[true_zero_last - 1];
               if(b1 == EMPTY_VALUE || MathAbs(b1) > zero_band)
                  break;
               true_zero_last--;
              }

            int run_len = true_zero_first - true_zero_last + 1;
            if(run_len >= InpMinZeroRunBars)
              {
               if(true_zero_first >= first_stable_mark_bar && true_zero_first <= bars_available - 2 &&
                  IsSlotFree(true_zero_first,bars_available,marker_safety_radius,marker_used))
                 {
                  g_marks[true_zero_first] = g_histogram[true_zero_first];
                  marker_used[true_zero_first] = 1;
                 }
               if(true_zero_last >= first_stable_mark_bar && true_zero_last <= bars_available - 2 &&
                  IsSlotFree(true_zero_last,bars_available,marker_safety_radius,marker_used))
                 {
                  g_marks[true_zero_last] = g_histogram[true_zero_last];
                  marker_used[true_zero_last] = 1;
                 }
              }

            in_zero_run = false;
            zero_run_first = -1;
            zero_run_last = -1;
           }
        }

      // Em modo buraco-only, nao bloqueia perto de zero para nao "sumir" marcacoes.
      if(is_zero && !use_hole_only_markers)
         continue;

      if(use_hole_only_markers)
        {
         // Passo 1 (legado/forte): preserva as bolinhas que ja existiam antes.
         const double strict_zero_band = MathMax(0.0,InpZeroTolerance);
         bool strict_hole = IsHoleCandidateAt(i,bars_available,g_histogram,strict_zero_band);
         if(strict_hole)
           {
            int strict_idx = FindBestHoleCenter(i,bars_available,g_histogram,strict_zero_band,InpHoleRelocationRadius);
            if(IsSlotFree(strict_idx,bars_available,marker_safety_radius,marker_used))
              {
               g_marks[strict_idx] = g_histogram[strict_idx];
               marker_used[strict_idx] = 1;
              }
           }

         // Passo 2 (extra/sensivel): adiciona novas bolinhas sem remover as anteriores.
         bool extra_hole = IsLooseHoleCandidateAt(i,bars_available,g_histogram);
         if(extra_hole)
           {
            int extra_idx = FindBestLooseHoleCenter(i,bars_available,g_histogram,InpHoleRelocationRadius);
            if(IsSlotFree(extra_idx,bars_available,marker_safety_radius,marker_used))
              {
               g_marks[extra_idx] = g_histogram[extra_idx];
               marker_used[extra_idx] = 1;
              }
           }
        }

      // Topos/prateleiras desativados neste modo para garantir
      // que nenhuma bolinha fique em pico.
     }

   static bool s_was_showing_main_markers = false;
   if(InpShowMarkersOnMainChart)
     {
      // Mantem o chart principal 1:1 com o buffer g_marks (sem acumular "sinal fantasma").
      // Opera apenas em barra nova (ja garantido no retorno antecipado acima).
      ClearMainChartMarkers();

      long first_visible_l = ChartGetInteger(ChartID(),CHART_FIRST_VISIBLE_BAR,0);
      long visible_bars_l = ChartGetInteger(ChartID(),CHART_VISIBLE_BARS,0);
      int left = bars_available - 2;
      int right = MathMax(first_stable_mark_bar,left - 800); // fallback seguro

      if(first_visible_l >= first_stable_mark_bar && visible_bars_l > 0)
        {
         left = (int)MathMin((long)(bars_available - 2),first_visible_l);
         right = left - (int)visible_bars_l - 50; // pequena folga lateral
         if(right < first_stable_mark_bar)
            right = first_stable_mark_bar;
        }

      for(int i = left; i >= right; --i)
        {
         string marker_name = StringFormat("%smark_%I64d",g_marker_prefix,(long)time[i]);
         if(g_marks[i] == EMPTY_VALUE)
            continue;

         // No chart principal, sempre no fundo do corpo da vela (buraco),
         // nunca na ponta do pavio e nunca no topo.
         double marker_price = MathMin(open[i],close[i]);
         if(InpMainMarkerOffsetPoints > 0)
            marker_price -= InpMainMarkerOffsetPoints * _Point;
         DrawMainChartMarker(marker_name,time[i],marker_price);
        }
      s_was_showing_main_markers = true;
     }
   else
     {
      if(s_was_showing_main_markers)
        {
         ClearMainChartMarkers();
         s_was_showing_main_markers = false;
        }
     }
//--- return value of prev_calculated for next call
   return(rates_total);
  }
//+------------------------------------------------------------------+
