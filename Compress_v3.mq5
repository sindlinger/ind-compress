//+------------------------------------------------------------------+
//|                                           DeflectonHistogram.mq5 |
//|                                  Copyright 2026, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.22"
#property indicator_separate_window
#property indicator_minimum 0.0
#property indicator_maximum 100.0
#property indicator_buffers 4
#property indicator_plots   3
#property indicator_label1  "BB Compression"
#property indicator_type1   DRAW_COLOR_HISTOGRAM
#property indicator_color1  clrLime,clrRed
#property indicator_width1  2
#property indicator_label2  "Compression MA"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrOrange
#property indicator_width2  1
#property indicator_label3  "DomPeriod"
#property indicator_type3   DRAW_LINE
#property indicator_color3  clrDeepSkyBlue
#property indicator_width3  1

#include <spectralib/SpectralImpl.mqh>
#include <spectralib/SpectralHilbert.mqh>

enum ENUM_COMPRESSION_PLOT_MODE
  {
   COMPRESSION_AS_HISTOGRAM = 0,
   COMPRESSION_AS_LINE      = 1
  };

input int                InpBandsPeriod       = 17;
input int                InpBandsShift        = 0;
input double             InpBandsDeviation    = 1;
input ENUM_APPLIED_PRICE InpBandsAppliedPrice = PRICE_CLOSE;
input bool               InpShowBandsOnMainChart = true;
input int                InpNormalizePeriod   = 17;
input ENUM_COMPRESSION_PLOT_MODE InpCompressionPlotMode = COMPRESSION_AS_LINE;
input int                InpMAPeriod          = 9;
input int                InpSignalLeadBars    = 1;
input bool               InpInvertCompression = false;

input group "BB Midline Velocity (Interno)"
input int                InpVelFastPeriod     = 3;
input int                InpVelMidPeriod      = 8;
input int                InpVelSlowPeriod     = 21;

input group "Dominant Frequency (GPU)"
input bool               InpGpuFreqEnable         = true;
input bool               InpGpuFreqUseMA          = true;
input bool               InpGpuFreqUpdateOnNewBar = true;
input int                InpGpuFreqWindowBars     = 256;
input int                InpGpuFreqMinPeriod      = 3;
input int                InpGpuFreqMaxPeriod      = 64;
input int                InpGpuStftNperseg        = 64;
input int                InpGpuStftOverlap        = 48;
input int                InpGpuStftNfft           = 256;
input string             InpGpuStftWindow         = "hann";
input bool               InpGpuFreqShowOnTitle    = true;
input bool               InpGpuFreqWarnOnFail     = true;
input bool               InpGpuFreqPlotPeriod     = false;
input bool               InpGpuFreqShowLabel      = true;
input int                InpGpuFreqLabelFontSize  = 18;
input string             InpGpuFreqLabelFont      = "Arial Black";
input int                InpGpuFreqLabelCorner    = CORNER_RIGHT_UPPER;
input int                InpGpuFreqLabelX         = 220;
input int                InpGpuFreqLabelY         = 22;
input color              InpGpuFreqLabelColorHigh = clrLime;
input color              InpGpuFreqLabelColorMid  = clrGold;
input color              InpGpuFreqLabelColorLow  = clrTomato;
input color              InpGpuFreqLabelColorFail = clrRed;

double g_histogram[];
double g_histogram_color[];
double g_ma[];
double g_dom_period_plot[];
double g_upper[];
double g_lower[];
double g_middle[];
int    g_bands_handle = INVALID_HANDLE;
string g_bands_shortname = "";
bool   g_bands_added_to_main_chart = false;
string g_shortname_base = "";
string g_gpu_label_name = "";
double g_gpu_dom_freq = 0.0;
double g_gpu_dom_period = 0.0;
double g_gpu_dom_snr = 0.0;
double g_gpu_inst_freq = 0.0;
double g_gpu_inst_period = 0.0;
datetime g_gpu_last_update_time = 0;
string g_gpu_last_fail = "";
bool   g_gpu_warned = false;
bool   g_gpu_runtime_enable = false;
int    g_gpu_window_bars = 0;
int    g_gpu_min_period = 0;
int    g_gpu_max_period = 0;
int    g_gpu_stft_nperseg = 0;
int    g_gpu_stft_overlap = 0;
int    g_gpu_stft_nfft = 0;

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
double SMAAt(const double &src[], const int i, const int period, const int bars_available)
  {
   if(period < 1 || i < 0 || i >= bars_available)
      return EMPTY_VALUE;

   int end_index = i + period - 1;
   if(end_index >= bars_available)
      end_index = bars_available - 1;

   double sum = 0.0;
   int count = 0;
   for(int j = i; j <= end_index; ++j)
     {
      if(src[j] == EMPTY_VALUE || !MathIsValidNumber(src[j]))
         continue;
      sum += src[j];
      count++;
     }

   if(count <= 0)
      return EMPTY_VALUE;
   return sum / (double)count;
  }

//+------------------------------------------------------------------+
double MedianCopy(const double &src[])
  {
   const int n = ArraySize(src);
   if(n <= 0)
      return 0.0;

   double tmp[];
   ArrayCopy(tmp,src);
   ArraySort(tmp);
   if((n % 2) == 1)
      return tmp[n / 2];
   return 0.5 * (tmp[n / 2 - 1] + tmp[n / 2]);
  }

//+------------------------------------------------------------------+
bool BuildChronoWindowFromSeries(const double &src_series[],
                                 const int bars_available,
                                 const int window_bars,
                                 double &out[])
  {
   if(window_bars < 16)
      return false;
   if(window_bars > bars_available)
      return false;
   if(ArrayResize(out,window_bars) != window_bars)
      return false;
   ArraySetAsSeries(out,false);

   bool has_prev = false;
   double prev = 0.0;
   for(int i = 0; i < window_bars; ++i)
     {
      const int src_idx = window_bars - 1 - i; // 0->bar0, 1->bar1 ...
      double v = src_series[src_idx];
      if(v == EMPTY_VALUE || !MathIsValidNumber(v))
        {
         if(!has_prev)
            return false;
         v = prev;
        }
      else
        {
         prev = v;
         has_prev = true;
        }
      out[i] = v;
     }
   return true;
  }

//+------------------------------------------------------------------+
bool ComputeDominantFrequencyAstftGpu(const double &x_chrono[],
                                      const int min_period,
                                      const int max_period,
                                      const string window_name,
                                      const int nperseg_in,
                                      const int noverlap_in,
                                      const int nfft_in,
                                      double &out_freq,
                                      double &out_period,
                                      double &out_snr,
                                      string &out_reason)
  {
   out_freq = 0.0;
   out_period = 0.0;
   out_snr = 0.0;
   out_reason = "";

   const int N = ArraySize(x_chrono);
   if(N < 16)
     {
      out_reason = "window_short";
      return false;
     }

   int nperseg = nperseg_in;
   if(nperseg < 8)
      nperseg = 8;
   if(nperseg > N)
      nperseg = N;

   int noverlap = noverlap_in;
   if(noverlap < 0)
      noverlap = 0;
   if(noverlap >= nperseg)
      noverlap = nperseg - 1;

   int nfft = (nfft_in > 0 ? nfft_in : NextPow2(nperseg));
   if(nfft < nperseg)
      nfft = NextPow2(nperseg);

   double x[];
   ArrayCopy(x,x_chrono);
   ArraySetAsSeries(x,false);
   double mean = 0.0;
   for(int i = 0; i < N; ++i)
      mean += x[i];
   mean /= (double)N;
   for(int i = 0; i < N; ++i)
      x[i] -= mean;

   double freqs[];
   double t[];
   matrixc Z;
   if(!stft_1d_matrixc(x,1.0,window_name,nperseg,noverlap,nfft,0,true,"spectrum",freqs,t,Z))
     {
      out_reason = "stft_fail";
      return false;
     }

   const int nseg = (int)Z.Rows();
   const int nfreq = (int)Z.Cols();
   if(nseg <= 0 || nfreq <= 1 || ArraySize(freqs) <= 1)
     {
      out_reason = "stft_empty";
      return false;
     }

   const double fmin = 1.0 / (double)MathMax(1,max_period);
   const double fmax = 1.0 / (double)MathMax(1,min_period);
   if(fmax <= fmin)
     {
      out_reason = "period_range_invalid";
      return false;
     }

   double avg_mag[];
   if(ArrayResize(avg_mag,nfreq) != nfreq)
     {
      out_reason = "alloc_avg_fail";
      return false;
     }
   ArrayInitialize(avg_mag,0.0);

   for(int s = 0; s < nseg; ++s)
     {
      for(int k = 1; k < nfreq; ++k)
        {
         complex z = Z[s][k];
         avg_mag[k] += MathSqrt(z.real * z.real + z.imag * z.imag);
        }
     }
   for(int k = 1; k < nfreq; ++k)
      avg_mag[k] /= (double)nseg;

   int inband_count = 0;
   int kbest = -1;
   double best_mag = -1.0;
   for(int k = 1; k < nfreq && k < ArraySize(freqs); ++k)
     {
      const double f = freqs[k];
      if(f < fmin || f > fmax)
         continue;
      inband_count++;
      if(avg_mag[k] > best_mag)
        {
         best_mag = avg_mag[k];
         kbest = k;
        }
     }

   if(inband_count <= 0)
     {
      out_reason = "no_bins_in_band";
      return false;
     }
   if(kbest < 0 || best_mag <= 0.0)
     {
      out_reason = "no_peak_in_band";
      return false;
     }

   double band_vals[];
   if(ArrayResize(band_vals,inband_count) != inband_count)
     {
      out_reason = "alloc_band_fail";
      return false;
     }
   int bi = 0;
   for(int k = 1; k < nfreq && k < ArraySize(freqs); ++k)
     {
      const double f = freqs[k];
      if(f < fmin || f > fmax)
         continue;
      band_vals[bi++] = avg_mag[k];
     }

   const double med = MedianCopy(band_vals);
   out_freq = freqs[kbest];
   out_period = (out_freq > 1e-12 ? 1.0 / out_freq : 0.0);
   out_snr = (med > 1e-12 ? best_mag / med : 0.0);
   out_reason = "";
   return true;
  }

//+------------------------------------------------------------------+
bool ComputeInstantFrequencyHilbertGpu(const double &x_chrono[],
                                       double &out_freq,
                                       double &out_period,
                                       string &out_reason)
  {
   out_freq = 0.0;
   out_period = 0.0;
   out_reason = "";

   const int N = ArraySize(x_chrono);
   if(N < 16)
     {
      out_reason = "window_short";
      return false;
     }

   double x[];
   ArrayCopy(x,x_chrono);
   ArraySetAsSeries(x,false);
   double mean = 0.0;
   for(int i = 0; i < N; ++i)
      mean += x[i];
   mean /= (double)N;
   for(int i = 0; i < N; ++i)
      x[i] -= mean;

   Complex64 analytic[];
   if(!hilbert_analytic_gpu(x,analytic))
     {
      out_reason = "hilbert_fail";
      return false;
     }

   const int n = ArraySize(analytic);
   if(n < 3)
     {
      out_reason = "analytic_short";
      return false;
     }

   const int i1 = n - 2;
   const int i0 = n - 1;
   double phi1 = MathArctan2(analytic[i1].im,analytic[i1].re);
   double phi0 = MathArctan2(analytic[i0].im,analytic[i0].re);
   double dphi = phi0 - phi1;
   const double kPi = 3.14159265358979323846;
   if(dphi > kPi)
      dphi -= 2.0 * kPi;
   else if(dphi < -kPi)
      dphi += 2.0 * kPi;

   out_freq = MathAbs(dphi) / (2.0 * kPi); // cycles/bar
   if(out_freq <= 1e-9 || !MathIsValidNumber(out_freq))
     {
      out_reason = "inst_freq_zero";
      out_freq = 0.0;
      return false;
     }

   out_period = 1.0 / out_freq;
   out_reason = "";
   return true;
  }

//+------------------------------------------------------------------+
void UpdateShortName()
  {
   string name = g_shortname_base;
   if(g_gpu_runtime_enable && InpGpuFreqShowOnTitle)
     {
      if(g_gpu_dom_freq > 0.0 && g_gpu_inst_freq > 0.0)
         name += StringFormat(" | Fdom=%.4f Pdom=%.1f | Finst=%.4f Pinst=%.1f SNR=%.2f",
                              g_gpu_dom_freq,
                              g_gpu_dom_period,
                              g_gpu_inst_freq,
                              g_gpu_inst_period,
                              g_gpu_dom_snr);
      else if(g_gpu_last_fail != "")
         name += " | GPU: " + g_gpu_last_fail;
     }
   IndicatorSetString(INDICATOR_SHORTNAME,name);
  }

//+------------------------------------------------------------------+
void RemoveGpuFreqLabel()
  {
   if(g_gpu_label_name == "")
      return;
   if(ObjectFind(0,g_gpu_label_name) >= 0)
      ObjectDelete(0,g_gpu_label_name);
  }

//+------------------------------------------------------------------+
void EnsureGpuFreqLabel()
  {
   if(g_gpu_label_name == "")
      g_gpu_label_name = StringFormat("CMP_GPUFREQ_%I64d_%s_%d",ChartID(),_Symbol,(int)Period());

   if(ObjectFind(0,g_gpu_label_name) < 0)
     {
      if(!ObjectCreate(0,g_gpu_label_name,OBJ_LABEL,0,0,0))
         return;
      ObjectSetInteger(0,g_gpu_label_name,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,g_gpu_label_name,OBJPROP_SELECTED,false);
      ObjectSetInteger(0,g_gpu_label_name,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,g_gpu_label_name,OBJPROP_BACK,false);
     }

   ENUM_ANCHOR_POINT anchor = ANCHOR_LEFT_UPPER;
   if(InpGpuFreqLabelCorner == CORNER_RIGHT_UPPER)
      anchor = ANCHOR_RIGHT_UPPER;
   else if(InpGpuFreqLabelCorner == CORNER_RIGHT_LOWER)
      anchor = ANCHOR_RIGHT_LOWER;
   else if(InpGpuFreqLabelCorner == CORNER_LEFT_LOWER)
      anchor = ANCHOR_LEFT_LOWER;

   ObjectSetInteger(0,g_gpu_label_name,OBJPROP_CORNER,InpGpuFreqLabelCorner);
   ObjectSetInteger(0,g_gpu_label_name,OBJPROP_ANCHOR,anchor);
   ObjectSetInteger(0,g_gpu_label_name,OBJPROP_XDISTANCE,InpGpuFreqLabelX);
   ObjectSetInteger(0,g_gpu_label_name,OBJPROP_YDISTANCE,InpGpuFreqLabelY);
   ObjectSetInteger(0,g_gpu_label_name,OBJPROP_FONTSIZE,InpGpuFreqLabelFontSize);
   ObjectSetString(0,g_gpu_label_name,OBJPROP_FONT,InpGpuFreqLabelFont);
  }

//+------------------------------------------------------------------+
void UpdateGpuFreqLabel()
  {
   if(!g_gpu_runtime_enable || !InpGpuFreqShowLabel)
     {
      RemoveGpuFreqLabel();
      return;
     }

   EnsureGpuFreqLabel();
   if(ObjectFind(0,g_gpu_label_name) < 0)
      return;

   color c = InpGpuFreqLabelColorFail;
   string txt = "GPU DOM FREQ: --\nGPU DOM PERIOD: --\nGPU INST FREQ: --\nSNR: --";

   if(g_gpu_last_fail != "")
     {
      txt = "GPU FREQ FAIL\n" + g_gpu_last_fail;
      c = InpGpuFreqLabelColorFail;
     }
   else if(g_gpu_dom_freq > 0.0 && g_gpu_dom_period > 0.0)
     {
      txt = StringFormat("GPU DOM FREQ: %.4f cyc/bar\nGPU DOM PERIOD: %.1f bars\nGPU INST FREQ: %.4f cyc/bar\nSNR: %.2f",
                         g_gpu_dom_freq,
                         g_gpu_dom_period,
                         g_gpu_inst_freq,
                         g_gpu_dom_snr);

      if(g_gpu_dom_snr >= 3.0)
         c = InpGpuFreqLabelColorHigh;
      else if(g_gpu_dom_snr >= 1.5)
         c = InpGpuFreqLabelColorMid;
      else
         c = InpGpuFreqLabelColorLow;
     }

   ObjectSetInteger(0,g_gpu_label_name,OBJPROP_COLOR,c);
   ObjectSetString(0,g_gpu_label_name,OBJPROP_TEXT,txt);
  }

//+------------------------------------------------------------------+
//| Configura modo de plot do indicador principal                    |
//+------------------------------------------------------------------+
void SetupCompressionPlotMode()
  {
   int lead = InpSignalLeadBars;
   if(lead < 0)
      lead = 0;
   if(lead > 5)
      lead = 5;
   const int plot_shift = -lead; // desloca para frente (visual) para compensar 1 barra de atraso

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

   PlotIndexSetInteger(0,PLOT_SHIFT,plot_shift);
   PlotIndexSetInteger(1,PLOT_SHIFT,plot_shift);
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
   SetIndexBuffer(3,g_dom_period_plot,INDICATOR_DATA);

   ArraySetAsSeries(g_histogram,true);
   ArraySetAsSeries(g_histogram_color,true);
   ArraySetAsSeries(g_ma,true);
   ArraySetAsSeries(g_dom_period_plot,true);

   PlotIndexSetDouble(0,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   PlotIndexSetDouble(1,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   PlotIndexSetDouble(2,PLOT_EMPTY_VALUE,EMPTY_VALUE);

   PlotIndexSetInteger(0,PLOT_COLOR_INDEXES,2);
   PlotIndexSetInteger(0,PLOT_LINE_COLOR,0,clrLime);
   PlotIndexSetInteger(0,PLOT_LINE_COLOR,1,clrRed);

   SetupCompressionPlotMode();
   if(!InpGpuFreqPlotPeriod)
      PlotIndexSetInteger(2,PLOT_DRAW_TYPE,DRAW_NONE);

   g_shortname_base = StringFormat("BB Compression (%d, %.2f) + MA(%d) | DirVel(%d/%d/%d)",
                                   InpBandsPeriod,
                                   InpBandsDeviation,
                                   InpMAPeriod,
                                   InpVelFastPeriod,
                                   InpVelMidPeriod,
                                   InpVelSlowPeriod);
   UpdateShortName();

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
   if(InpVelFastPeriod < 1 || InpVelMidPeriod < 1 || InpVelSlowPeriod < 1)
     {
      Print("Periodos de velocidade precisam ser >= 1.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpVelFastPeriod > InpVelMidPeriod || InpVelMidPeriod > InpVelSlowPeriod)
     {
      Print("Use periodos de velocidade em ordem: Fast <= Mid <= Slow.");
      return INIT_PARAMETERS_INCORRECT;
     }
   g_gpu_runtime_enable = InpGpuFreqEnable;
   g_gpu_window_bars = InpGpuFreqWindowBars;
   g_gpu_min_period = InpGpuFreqMinPeriod;
   g_gpu_max_period = InpGpuFreqMaxPeriod;
   g_gpu_stft_nperseg = InpGpuStftNperseg;
   g_gpu_stft_overlap = InpGpuStftOverlap;
   g_gpu_stft_nfft = InpGpuStftNfft;

   if(g_gpu_runtime_enable)
     {
      if(g_gpu_window_bars < 32)
        {
         PrintFormat("GPU Freq: InpGpuFreqWindowBars=%d ajustado para 32.",g_gpu_window_bars);
         g_gpu_window_bars = 32;
        }
      if(g_gpu_min_period < 2)
        {
         PrintFormat("GPU Freq: InpGpuFreqMinPeriod=%d ajustado para 2.",g_gpu_min_period);
         g_gpu_min_period = 2;
        }
      if(g_gpu_max_period <= g_gpu_min_period)
        {
         int old_max = g_gpu_max_period;
         g_gpu_max_period = g_gpu_min_period + 1;
         PrintFormat("GPU Freq: MaxPeriod=%d invalido para MinPeriod=%d; ajustado para %d.",
                     old_max,
                     g_gpu_min_period,
                     g_gpu_max_period);
        }
      if(g_gpu_stft_nperseg < 8)
        {
         PrintFormat("GPU Freq: InpGpuStftNperseg=%d ajustado para 8.",g_gpu_stft_nperseg);
         g_gpu_stft_nperseg = 8;
        }
      if(g_gpu_stft_overlap < 0)
        {
         PrintFormat("GPU Freq: InpGpuStftOverlap=%d ajustado para 0.",g_gpu_stft_overlap);
         g_gpu_stft_overlap = 0;
        }
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
   RemoveGpuFreqLabel();

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

   const int max_lookback = MathMax(InpNormalizePeriod,MathMax(InpMAPeriod,InpVelSlowPeriod));
   const bool full_recalc = (prev_calculated <= 0 || prev_calculated > rates_total);
   int delta_bars = (full_recalc ? rates_total : rates_total - prev_calculated);
   if(delta_bars < 0)
      delta_bars = rates_total;

   int recalc_bars = (full_recalc ? rates_total : delta_bars + max_lookback + 4);
   if(recalc_bars < 1)
      recalc_bars = 1;
   if(recalc_bars > rates_total)
      recalc_bars = rates_total;

   int copy_count = recalc_bars + max_lookback + 2;
   if(g_gpu_runtime_enable && g_gpu_window_bars > copy_count)
      copy_count = g_gpu_window_bars;
   if(copy_count > rates_total)
      copy_count = rates_total;

   if(ArraySize(g_upper) < rates_total)
      ArrayResize(g_upper,rates_total);
   if(ArraySize(g_lower) < rates_total)
      ArrayResize(g_lower,rates_total);
   if(ArraySize(g_middle) < rates_total)
      ArrayResize(g_middle,rates_total);
   ArraySetAsSeries(g_upper,true);
   ArraySetAsSeries(g_lower,true);
   ArraySetAsSeries(g_middle,true);

   const int bands_capacity = MathMin(ArraySize(g_upper),MathMin(ArraySize(g_lower),ArraySize(g_middle)));
   if(bands_capacity <= 0)
      return prev_calculated;
   if(copy_count > bands_capacity)
      copy_count = bands_capacity;
   if(copy_count <= 0)
      return prev_calculated;

   int copied_middle = CopyBuffer(g_bands_handle,0,0,copy_count,g_middle);
   int copied_upper  = CopyBuffer(g_bands_handle,1,0,copy_count,g_upper);
   int copied_lower  = CopyBuffer(g_bands_handle,2,0,copy_count,g_lower);

   if(copied_middle <= 0 || copied_upper <= 0 || copied_lower <= 0)
      return prev_calculated;

   int bars_available = MathMin(copy_count,MathMin(copied_middle,MathMin(copied_upper,copied_lower)));
   if(bars_available <= 0)
      return prev_calculated;
   if(recalc_bars > bars_available)
      recalc_bars = bars_available;
   const int calc_start = recalc_bars - 1;
   if(calc_start < 0)
      return prev_calculated;

   // Limpa barras sem dados suficientes apenas quando copiando historico completo.
   if(copy_count == rates_total)
     {
      for(int i = rates_total - 1; i >= bars_available; --i)
        {
         g_histogram[i] = EMPTY_VALUE;
         g_histogram_color[i] = 0.0;
         g_ma[i] = EMPTY_VALUE;
         g_dom_period_plot[i] = EMPTY_VALUE;
        }
     }
   if(full_recalc)
     {
      for(int i = bars_available - 1; i >= 0; --i)
         g_dom_period_plot[i] = EMPTY_VALUE;
     }

   for(int i = calc_start; i >= 0; --i)
     {
      if(g_upper[i] == EMPTY_VALUE || g_lower[i] == EMPTY_VALUE ||
         !MathIsValidNumber(g_upper[i]) || !MathIsValidNumber(g_lower[i]))
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
      for(int j = i; j <= end_index; ++j)
        {
         if(g_upper[j] == EMPTY_VALUE || g_lower[j] == EMPTY_VALUE ||
            !MathIsValidNumber(g_upper[j]) || !MathIsValidNumber(g_lower[j]))
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
      g_histogram_color[i] = 0.0; // cor fixa (sem votacao por velocidade)
     }

   // A media pode adicionar atraso visual, como qualquer smoothing.
   for(int i = calc_start; i >= 0; --i)
     {
      g_ma[i] = SMAAt(g_histogram, i, InpMAPeriod, bars_available);
     }

   // Evita rastro horizontal com valores antigos do plot de periodo.
   for(int i = calc_start; i >= 0; --i)
      g_dom_period_plot[i] = EMPTY_VALUE;

   // Frequencia dominante / instantanea (GPU only via spectralib).
   if(g_gpu_runtime_enable)
     {
      bool should_update = true;
      if(InpGpuFreqUpdateOnNewBar && bars_available > 0)
        {
         datetime anchor_time = time[0];
         should_update = (anchor_time != g_gpu_last_update_time);
         if(should_update)
            g_gpu_last_update_time = anchor_time;
        }

      if(should_update)
        {
         double xwin[];
         bool have_source = false;
         if(InpGpuFreqUseMA)
            have_source = BuildChronoWindowFromSeries(g_ma,bars_available,g_gpu_window_bars,xwin);
         if(!have_source)
            have_source = BuildChronoWindowFromSeries(g_histogram,bars_available,g_gpu_window_bars,xwin);

         if(!have_source)
           {
            g_gpu_last_fail = "source_window_unavailable";
            g_gpu_dom_freq = 0.0;
            g_gpu_dom_period = 0.0;
            g_gpu_dom_snr = 0.0;
            g_gpu_inst_freq = 0.0;
            g_gpu_inst_period = 0.0;
           }
         else
           {
            string reason_dom = "";
            string reason_inst = "";
            double dom_freq = 0.0;
            double dom_period = 0.0;
            double dom_snr = 0.0;
            double inst_freq = 0.0;
            double inst_period = 0.0;

            bool dom_ok = ComputeDominantFrequencyAstftGpu(xwin,
                                                           g_gpu_min_period,
                                                           g_gpu_max_period,
                                                           InpGpuStftWindow,
                                                           g_gpu_stft_nperseg,
                                                           g_gpu_stft_overlap,
                                                           g_gpu_stft_nfft,
                                                           dom_freq,
                                                           dom_period,
                                                           dom_snr,
                                                           reason_dom);
            bool inst_ok = ComputeInstantFrequencyHilbertGpu(xwin,
                                                             inst_freq,
                                                             inst_period,
                                                             reason_inst);

            if(dom_ok)
              {
               g_gpu_dom_freq = dom_freq;
               g_gpu_dom_period = dom_period;
               g_gpu_dom_snr = dom_snr;
              }
            else
              {
               g_gpu_dom_freq = 0.0;
               g_gpu_dom_period = 0.0;
               g_gpu_dom_snr = 0.0;
              }

            if(inst_ok)
              {
               g_gpu_inst_freq = inst_freq;
               g_gpu_inst_period = inst_period;
              }
            else
              {
               g_gpu_inst_freq = 0.0;
               g_gpu_inst_period = 0.0;
              }

            if(dom_ok && inst_ok)
               g_gpu_last_fail = "";
            else if(!dom_ok && !inst_ok)
               g_gpu_last_fail = "dom=" + reason_dom + ",inst=" + reason_inst;
            else if(!dom_ok)
               g_gpu_last_fail = "dom=" + reason_dom;
            else
               g_gpu_last_fail = "inst=" + reason_inst;
           }
        }
     }
   else
     {
      g_gpu_last_fail = "";
      g_gpu_dom_freq = 0.0;
      g_gpu_dom_period = 0.0;
      g_gpu_dom_snr = 0.0;
      g_gpu_inst_freq = 0.0;
      g_gpu_inst_period = 0.0;
     }

   if(g_gpu_runtime_enable && g_gpu_last_fail != "")
     {
      if(InpGpuFreqWarnOnFail && !g_gpu_warned)
        {
         Alert("Compress_v2 GPU frequency falhou: " + g_gpu_last_fail);
         g_gpu_warned = true;
        }
     }
   else if(g_gpu_runtime_enable)
     {
      g_gpu_warned = false;
     }

   if(g_gpu_runtime_enable && InpGpuFreqPlotPeriod &&
      g_gpu_dom_period > 0.0 && MathIsValidNumber(g_gpu_dom_period) &&
      g_gpu_dom_period >= (double)g_gpu_min_period &&
      g_gpu_dom_period <= (double)g_gpu_max_period)
      g_dom_period_plot[0] = g_gpu_dom_period;
   else
      g_dom_period_plot[0] = EMPTY_VALUE;

   UpdateShortName();
   UpdateGpuFreqLabel();

//--- return value of prev_calculated for next call
   return(rates_total);
  }
//+------------------------------------------------------------------+
