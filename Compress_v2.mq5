//+------------------------------------------------------------------+
//|                                           DeflectonHistogram.mq5 |
//|                                  Copyright 2026, MetaQuotes Ltd. |
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2026, MetaQuotes Ltd."
#property link      "https://www.mql5.com"
#property version   "1.23"
#property indicator_separate_window
#property indicator_minimum 0.0
#property indicator_maximum 100.0
#property indicator_buffers 5
#property indicator_plots   4
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
#property indicator_label4  "DomCycle"
#property indicator_type4   DRAW_LINE
#property indicator_color4  clrWhite
#property indicator_width4  1

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
input bool               InpGpuFreqPlotCycle      = false;
input double             InpGpuCycleAmplitude     = 45.0;
input bool               InpGpuFreqShowLabel      = true;
input bool               InpGpuFreqShowExtended   = false;
input double             InpGpuSNRMidThreshold    = 1.5;
input double             InpGpuSNRHighThreshold   = 3.0;
input double             InpGpuFastCycleMaxPeriod = 10.0;
input double             InpGpuSlowCycleMinPeriod = 24.0;
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
double g_dom_cycle_plot[];
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
double g_gpu_inst_phase0 = 0.0;
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
double GetAppliedPriceAt(const int index,
                         const double &open[],
                         const double &high[],
                         const double &low[],
                         const double &close[])
  {
   switch(InpBandsAppliedPrice)
     {
      case PRICE_OPEN:    return open[index];
      case PRICE_HIGH:    return high[index];
      case PRICE_LOW:     return low[index];
      case PRICE_MEDIAN:  return 0.5 * (high[index] + low[index]);
      case PRICE_TYPICAL: return (high[index] + low[index] + close[index]) / 3.0;
      case PRICE_WEIGHTED:return (high[index] + low[index] + (2.0 * close[index])) / 4.0;
      case PRICE_CLOSE:
      default:            return close[index];
     }
  }

//+------------------------------------------------------------------+
bool ComputeBandsAtSeriesIndex(const int bar_index,
                               const int bars_available,
                               const double &open[],
                               const double &high[],
                               const double &low[],
                               const double &close[],
                               double &out_upper,
                               double &out_middle,
                               double &out_lower)
  {
   out_upper = EMPTY_VALUE;
   out_middle = EMPTY_VALUE;
   out_lower = EMPTY_VALUE;

   if(InpBandsPeriod < 1 || bars_available <= 0)
      return false;

   const int src_start = bar_index + InpBandsShift;
   if(src_start < 0)
      return false;

   const int src_end = src_start + InpBandsPeriod - 1;
   if(src_end >= bars_available)
      return false;

   double sum = 0.0;
   for(int i = src_start; i <= src_end; ++i)
     {
      const double p = GetAppliedPriceAt(i,open,high,low,close);
      if(!MathIsValidNumber(p))
         return false;
      sum += p;
     }
   const double mean = sum / (double)InpBandsPeriod;

   double var = 0.0;
   for(int i = src_start; i <= src_end; ++i)
     {
      const double p = GetAppliedPriceAt(i,open,high,low,close);
      const double d = p - mean;
      var += d * d;
     }
   const double stddev = MathSqrt(var / (double)InpBandsPeriod);

   out_middle = mean;
   out_upper = mean + (InpBandsDeviation * stddev);
   out_lower = mean - (InpBandsDeviation * stddev);
   return true;
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
                                       double &out_phase0,
                                       string &out_reason)
  {
   out_freq = 0.0;
   out_period = 0.0;
   out_phase0 = 0.0;
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
   out_phase0 = phi0;
   out_reason = "";
   return true;
  }

//+------------------------------------------------------------------+
void BuildDominantCyclePlot(const int bars_available,
                            const int window_bars,
                            const double dom_period,
                            const double phase0)
  {
   const int limit = MathMin(bars_available,window_bars);
   if(limit <= 0 || dom_period <= 1e-9 || !MathIsValidNumber(dom_period))
     {
      for(int i = 0; i < bars_available; ++i)
         g_dom_cycle_plot[i] = EMPTY_VALUE;
      return;
     }

   const double kPi = 3.14159265358979323846;
   const double step = 2.0 * kPi / dom_period;
   double amp = InpGpuCycleAmplitude;
   if(!MathIsValidNumber(amp))
      amp = 45.0;
   if(amp < 1.0)
      amp = 1.0;
   if(amp > 50.0)
      amp = 50.0;

   for(int i = 0; i < limit; ++i)
     {
      const double phase = phase0 - (step * (double)i);
      g_dom_cycle_plot[i] = ClampScore(50.0 + amp * MathSin(phase));
     }
   for(int i = limit; i < bars_available; ++i)
      g_dom_cycle_plot[i] = EMPTY_VALUE;
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

   double snr_mid = InpGpuSNRMidThreshold;
   double snr_high = InpGpuSNRHighThreshold;
   if(snr_mid <= 0.0)
      snr_mid = 1.5;
   if(snr_high <= snr_mid)
      snr_high = snr_mid + 0.5;

   if(g_gpu_last_fail != "")
     {
      txt = "GPU FREQ FAIL\n" + g_gpu_last_fail;
      c = InpGpuFreqLabelColorFail;
     }
   else if(g_gpu_dom_freq > 0.0 && g_gpu_dom_period > 0.0)
     {
      string q = "LOW";
      if(g_gpu_dom_snr >= snr_high)
         q = "HIGH";
      else if(g_gpu_dom_snr >= snr_mid)
         q = "MID";

      string cycle_class = "MEDIO";
      if(g_gpu_dom_period <= InpGpuFastCycleMaxPeriod)
         cycle_class = "RAPIDO";
      else if(g_gpu_dom_period >= InpGpuSlowCycleMinPeriod)
         cycle_class = "LENTO";

      string dir = "--";
      if(g_histogram[0] != EMPTY_VALUE && MathIsValidNumber(g_histogram[0]))
         dir = (g_histogram_color[0] <= 0.5 ? "UP" : "DOWN");

      if(InpGpuFreqShowExtended)
        {
         txt = StringFormat(
            "GPU DOM FREQ: %.4f cyc/bar\nGPU DOM PERIOD: %.1f bars\nGPU INST FREQ: %.4f cyc/bar\nSNR: %.2f (%s)\nSWING~: %.1f bars\nCYCLE: %s | DIR: %s",
            g_gpu_dom_freq,
            g_gpu_dom_period,
            g_gpu_inst_freq,
            g_gpu_dom_snr,
            q,
            0.5 * g_gpu_dom_period,
            cycle_class,
            dir
         );
        }
      else
        {
         txt = StringFormat("GPU DOM FREQ: %.4f cyc/bar\nGPU DOM PERIOD: %.1f bars\nGPU INST FREQ: %.4f cyc/bar\nSNR: %.2f",
                            g_gpu_dom_freq,
                            g_gpu_dom_period,
                            g_gpu_inst_freq,
                            g_gpu_dom_snr);
        }

      if(g_gpu_dom_snr >= snr_high)
         c = InpGpuFreqLabelColorHigh;
      else if(g_gpu_dom_snr >= snr_mid)
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
   SetIndexBuffer(3,g_dom_period_plot,INDICATOR_DATA);
   SetIndexBuffer(4,g_dom_cycle_plot,INDICATOR_DATA);

   ArraySetAsSeries(g_histogram,true);
   ArraySetAsSeries(g_histogram_color,true);
   ArraySetAsSeries(g_ma,true);
   ArraySetAsSeries(g_dom_period_plot,true);
   ArraySetAsSeries(g_dom_cycle_plot,true);

   PlotIndexSetDouble(0,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   PlotIndexSetDouble(1,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   PlotIndexSetDouble(2,PLOT_EMPTY_VALUE,EMPTY_VALUE);
   PlotIndexSetDouble(3,PLOT_EMPTY_VALUE,EMPTY_VALUE);

   PlotIndexSetInteger(0,PLOT_COLOR_INDEXES,2);
   PlotIndexSetInteger(0,PLOT_LINE_COLOR,0,clrLime);
   PlotIndexSetInteger(0,PLOT_LINE_COLOR,1,clrRed);

   SetupCompressionPlotMode();
   if(!InpGpuFreqPlotPeriod)
      PlotIndexSetInteger(2,PLOT_DRAW_TYPE,DRAW_NONE);
   if(!InpGpuFreqPlotCycle)
      PlotIndexSetInteger(3,PLOT_DRAW_TYPE,DRAW_NONE);

   g_gpu_runtime_enable = InpGpuFreqEnable;
   g_gpu_window_bars = InpGpuFreqWindowBars;
   g_gpu_min_period = InpGpuFreqMinPeriod;
   g_gpu_max_period = InpGpuFreqMaxPeriod;
   g_gpu_stft_nperseg = InpGpuStftNperseg;
   g_gpu_stft_overlap = InpGpuStftOverlap;
   g_gpu_stft_nfft = InpGpuStftNfft;

   g_shortname_base = StringFormat("BB Compression (%d, %.2f) + MA(%d)",
                                   InpBandsPeriod,
                                   InpBandsDeviation,
                                   InpMAPeriod);
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
      if(g_gpu_stft_overlap >= g_gpu_stft_nperseg)
        {
         int old_overlap = g_gpu_stft_overlap;
         g_gpu_stft_overlap = g_gpu_stft_nperseg - 1;
         if(g_gpu_stft_overlap < 0)
            g_gpu_stft_overlap = 0;
         PrintFormat("GPU Freq: overlap=%d ajustado para %d (nperseg=%d).",
                     old_overlap,
                     g_gpu_stft_overlap,
                     g_gpu_stft_nperseg);
        }
     }

   if(InpShowBandsOnMainChart)
      Print("Compress_v2: exibicao de Bollinger no grafico principal desativada (modo sem CopyBuffer).");
//---
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Indicator deinitialization                                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   RemoveGpuFreqLabel();
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
   if(rates_total <= 0)
      return 0;

   const bool draw_period_plot = InpGpuFreqPlotPeriod;
   const bool draw_cycle_plot = InpGpuFreqPlotCycle;

   const int max_lookback = MathMax(InpNormalizePeriod,InpMAPeriod);
   const bool full_recalc = (prev_calculated <= 0 || prev_calculated > rates_total);
   int delta_bars = (full_recalc ? rates_total : rates_total - prev_calculated);
   if(delta_bars < 0)
      delta_bars = rates_total;

   int recalc_bars = (full_recalc ? rates_total : delta_bars + max_lookback + 4);
   if(recalc_bars < 1)
      recalc_bars = 1;
   if(recalc_bars > rates_total)
      recalc_bars = rates_total;

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
   const int bars_available = MathMin(rates_total,bands_capacity);
   if(bars_available <= 0)
      return prev_calculated;
   if(recalc_bars > bars_available)
      recalc_bars = bars_available;
   const int calc_start = recalc_bars - 1;
   if(calc_start < 0)
      return prev_calculated;

   int bands_calc_max = calc_start + InpNormalizePeriod - 1;
   if(bands_calc_max < calc_start)
      bands_calc_max = calc_start;
   if(bands_calc_max >= bars_available)
      bands_calc_max = bars_available - 1;
   for(int i = bands_calc_max; i >= 0; --i)
     {
      double upper = EMPTY_VALUE;
      double middle = EMPTY_VALUE;
      double lower = EMPTY_VALUE;
      if(ComputeBandsAtSeriesIndex(i,bars_available,open,high,low,close,upper,middle,lower))
        {
         g_upper[i] = upper;
         g_middle[i] = middle;
         g_lower[i] = lower;
        }
      else
        {
         g_upper[i] = EMPTY_VALUE;
         g_middle[i] = EMPTY_VALUE;
         g_lower[i] = EMPTY_VALUE;
        }
     }

   if(full_recalc)
     {
      if(draw_period_plot)
        {
         for(int i = bars_available - 1; i >= 0; --i)
            g_dom_period_plot[i] = EMPTY_VALUE;
        }
      if(draw_cycle_plot)
        {
         for(int i = bars_available - 1; i >= 0; --i)
            g_dom_cycle_plot[i] = EMPTY_VALUE;
        }
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
      g_histogram_color[i] = 0.0; // Cor fixa para evitar sinal visual atrasado por filtros de direcao
     }

   // A media pode adicionar atraso visual, como qualquer smoothing.
   for(int i = calc_start; i >= 0; --i)
     {
      g_ma[i] = SMAAt(g_histogram, i, InpMAPeriod, bars_available);
     }

   if(draw_period_plot)
     {
      for(int i = calc_start; i >= 0; --i)
         g_dom_period_plot[i] = EMPTY_VALUE;
     }
   if(draw_cycle_plot)
     {
      for(int i = calc_start; i >= 0; --i)
         g_dom_cycle_plot[i] = EMPTY_VALUE;
     }

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
            double inst_phase0 = 0.0;

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
                                                             inst_phase0,
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
               g_gpu_inst_phase0 = inst_phase0;
              }
            else
              {
               g_gpu_inst_freq = 0.0;
               g_gpu_inst_period = 0.0;
               g_gpu_inst_phase0 = 0.0;
              }

            if(dom_ok && inst_ok)
               g_gpu_last_fail = "";
            else if(!dom_ok && !inst_ok)
               g_gpu_last_fail = "dom=" + reason_dom + ",inst=" + reason_inst;
            else if(!dom_ok)
               g_gpu_last_fail = "dom=" + reason_dom;
            else
               g_gpu_last_fail = "inst=" + reason_inst;

            if(draw_cycle_plot)
              {
               if(dom_ok && inst_ok)
                  BuildDominantCyclePlot(bars_available,g_gpu_window_bars,dom_period,inst_phase0);
               else
                  BuildDominantCyclePlot(bars_available,g_gpu_window_bars,0.0,0.0);
              }
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
      g_gpu_inst_phase0 = 0.0;
      if(draw_cycle_plot)
         BuildDominantCyclePlot(bars_available,g_gpu_window_bars,0.0,0.0);
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
