//+------------------------------------------------------------------+
//|                                        Compress_RevCross_v1.0.mq5|
//|  Modif auditavel (-100..+100), clean view                        |
//+------------------------------------------------------------------+
#property copyright "IndicatorsPack-2026"
#property link      ""
#property version   "5.20"
#property indicator_separate_window
#property indicator_buffers 4
#property indicator_plots   3
#property indicator_level1  0.0

#property indicator_label1  "Modif"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrWhite
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

#property indicator_label2  "CrossUp"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrLime
#property indicator_style2  STYLE_SOLID
#property indicator_width2  1

#property indicator_label3  "CrossDown"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrRed
#property indicator_style3  STYLE_SOLID
#property indicator_width3  1

input string InpSourcePath = "IndicatorsPack-2026\\Compress\\Compress_v2.4";
input int    InpSourceBufferIndex = 2;         // 2=Compression MA, 0=Compression base
input ENUM_APPLIED_PRICE InpPriceType = PRICE_CLOSE;
input int    InpSlopeLen = 5;                   // barras para inclinacao
enum EModifCalcMode { MODIF_SIMPLE_RATIO = 0, MODIF_ANGULAR_LEGACY = 1 };
input EModifCalcMode InpCalcMode = MODIF_SIMPLE_RATIO;
input int    InpNormEmaLen = 32;                // usado apenas no modo angular legacy
input int    InpModifSmoothLen = 4;             // suavizacao final do Modif
input double InpCrossThreshold = 35.0;          // limiar minimo de |Modif| para seta
input bool   InpShowModifLine = true;
input bool   InpUseClosedBarOnly = true;        // nao usa barra 0 em tempo real
input bool   InpShowInfoLabel = true;           // mostra formula da linha branca na subjanela

double g_modif[];
double g_cross_up[];
double g_cross_down[];
double g_src_work[];

int    g_source_handle = INVALID_HANDLE;
string g_source_path_used = "";
string g_short_name = "";
string g_info_label_name = "";

//+------------------------------------------------------------------+
double GetAppliedPrice(const int i,
                       const double &open[],
                       const double &high[],
                       const double &low[],
                       const double &close[])
  {
   switch(InpPriceType)
     {
      case PRICE_OPEN:     return open[i];
      case PRICE_HIGH:     return high[i];
      case PRICE_LOW:      return low[i];
      case PRICE_MEDIAN:   return (high[i] + low[i]) * 0.5;
      case PRICE_TYPICAL:  return (high[i] + low[i] + close[i]) / 3.0;
      case PRICE_WEIGHTED: return (high[i] + low[i] + close[i] + close[i]) * 0.25;
      case PRICE_CLOSE:
      default:             return close[i];
     }
  }

//+------------------------------------------------------------------+
double WrapPi(double x)
  {
   const double pi = 3.14159265358979323846;
   const double two_pi = 2.0 * pi;
   while(x > pi)  x -= two_pi;
   while(x < -pi) x += two_pi;
   return x;
  }

//+------------------------------------------------------------------+
double Clamp(double v, double lo, double hi)
  {
   if(v < lo) return lo;
   if(v > hi) return hi;
   return v;
  }

//+------------------------------------------------------------------+
void RemoveInfoLabel()
  {
   if(g_info_label_name == "")
      return;
   if(ObjectFind(0, g_info_label_name) >= 0)
      ObjectDelete(0, g_info_label_name);
  }

//+------------------------------------------------------------------+
void UpdateInfoLabel(const double modif_value)
  {
   if(!InpShowInfoLabel)
     {
      RemoveInfoLabel();
      return;
     }

   if(g_info_label_name == "")
      g_info_label_name = StringFormat("CRVC_INFO_%I64d_%s_%d", ChartID(), _Symbol, Period());

   int subwin = 1;
   if(g_short_name != "")
     {
      int w = ChartWindowFind(0, g_short_name);
      if(w >= 0)
         subwin = w;
     }

   if(ObjectFind(0, g_info_label_name) < 0)
     {
      if(!ObjectCreate(0, g_info_label_name, OBJ_LABEL, subwin, 0, 0))
         return;
      ObjectSetInteger(0, g_info_label_name, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, g_info_label_name, OBJPROP_XDISTANCE, 8);
      ObjectSetInteger(0, g_info_label_name, OBJPROP_YDISTANCE, 18);
      ObjectSetInteger(0, g_info_label_name, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, g_info_label_name, OBJPROP_SELECTED, false);
      ObjectSetInteger(0, g_info_label_name, OBJPROP_HIDDEN, true);
      ObjectSetString(0, g_info_label_name, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, g_info_label_name, OBJPROP_FONTSIZE, 9);
     }

   ObjectSetInteger(0, g_info_label_name, OBJPROP_COLOR, clrSilver);

   string txt = "LINHA BRANCA = MODIF\n";
   if(InpCalcMode == MODIF_SIMPLE_RATIO)
     {
      txt += "MODO: SIMPLE_RATIO (auditavel)\n";
      txt += "rp = slope(preco)/abs(preco_ref)\n";
      txt += "rc = slope(compress)/abs(compress_ref)\n";
      txt += "sim = 2*min(|rp|,|rc|)/( |rp|+|rc| )\n";
      txt += "raw = 100*sign(rp*rc)*sim\n";
      txt += "MODIF = EMA(raw, smooth)\n";
     }
   else
     {
      txt += "MODO: ANGULAR_LEGACY\n";
      txt += "raw = 100*(0.75*cos(dtheta) + 0.25*(2*mratio-1))\n";
      txt += "dtheta = atan(sp) - atan(sc)\n";
      txt += "sp = slope(preco)/EMA(abs(dpreco), norm)\n";
      txt += "sc = slope(compress)/EMA(abs(dcompress), norm)\n";
      txt += "MODIF = EMA(raw, smooth)\n";
     }
   txt += StringFormat("Modif atual = %.2f", modif_value);

   ObjectSetString(0, g_info_label_name, OBJPROP_TEXT, txt);
  }

//+------------------------------------------------------------------+
int TryCreateSourceHandle()
  {
   string candidates[5];
   candidates[0] = InpSourcePath;
   candidates[1] = "IndicatorsPack-2026\\Compress\\Compress_v2.4";
   candidates[2] = "Compress\\Compress_v2.4";
   candidates[3] = "Compress_v2.4";
   candidates[4] = "IndicatorsPack-2026\\Compress\\Compress_v2.4.ex5";

   for(int i=0; i<5; ++i)
     {
      if(candidates[i] == "")
         continue;
      int h = iCustom(_Symbol, _Period, candidates[i]);
      if(h != INVALID_HANDLE)
        {
         g_source_path_used = candidates[i];
         return h;
        }
     }
   return INVALID_HANDLE;
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   if(InpSourceBufferIndex < 0 || InpSourceBufferIndex > 15)
      return(INIT_PARAMETERS_INCORRECT);
   if(InpSlopeLen < 1)
      return(INIT_PARAMETERS_INCORRECT);
   if(InpNormEmaLen < 1)
      return(INIT_PARAMETERS_INCORRECT);
   if(InpModifSmoothLen < 1)
      return(INIT_PARAMETERS_INCORRECT);
   if(InpCrossThreshold < 0.0 || InpCrossThreshold > 100.0)
      return(INIT_PARAMETERS_INCORRECT);

   SetIndexBuffer(0, g_modif, INDICATOR_DATA);
   SetIndexBuffer(1, g_cross_up, INDICATOR_DATA);
   SetIndexBuffer(2, g_cross_down, INDICATOR_DATA);
   SetIndexBuffer(3, g_src_work, INDICATOR_CALCULATIONS);

   ArraySetAsSeries(g_modif, true);
   ArraySetAsSeries(g_cross_up, true);
   ArraySetAsSeries(g_cross_down, true);
   ArraySetAsSeries(g_src_work, true);

   PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetDouble(2, PLOT_EMPTY_VALUE, EMPTY_VALUE);
   PlotIndexSetInteger(1, PLOT_ARROW, 233);
   PlotIndexSetInteger(2, PLOT_ARROW, 234);

   if(!InpShowModifLine)
      PlotIndexSetInteger(0, PLOT_DRAW_TYPE, DRAW_NONE);

   g_source_handle = TryCreateSourceHandle();
   if(g_source_handle == INVALID_HANDLE)
     {
      PrintFormat("Compress_RevCross: failed to open source indicator. InputPath='%s', err=%d",
                  InpSourcePath, GetLastError());
      return(INIT_FAILED);
     }

   string mode_name = (InpCalcMode == MODIF_SIMPLE_RATIO ? "SIMPLE_RATIO" : "ANGULAR_LEGACY");
   g_short_name = StringFormat("Compress_RevCross v5.20 [%s slope=%d norm=%d smooth=%d thr=%.1f buf=%d | %s]",
                               mode_name, InpSlopeLen, InpNormEmaLen, InpModifSmoothLen, InpCrossThreshold,
                               InpSourceBufferIndex, g_source_path_used);
   IndicatorSetString(INDICATOR_SHORTNAME, g_short_name);
   UpdateInfoLabel(0.0);
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(g_source_handle != INVALID_HANDLE)
     {
      IndicatorRelease(g_source_handle);
      g_source_handle = INVALID_HANDLE;
     }
   RemoveInfoLabel();
  }

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
   if(g_source_handle == INVALID_HANDLE || rates_total < (InpSlopeLen + 5))
      return(0);

   ArraySetAsSeries(open, true);
   ArraySetAsSeries(high, true);
   ArraySetAsSeries(low, true);
   ArraySetAsSeries(close, true);

   double src_buf[];
   double price_raw[];
   if(ArrayResize(src_buf, rates_total) != rates_total ||
      ArrayResize(price_raw, rates_total) != rates_total)
      return(prev_calculated);

   ArraySetAsSeries(src_buf, true);
   ArraySetAsSeries(price_raw, true);

   int got_src = CopyBuffer(g_source_handle, InpSourceBufferIndex, 0, rates_total, src_buf);
   if(got_src <= 0 && InpSourceBufferIndex != 2)
      got_src = CopyBuffer(g_source_handle, 2, 0, rates_total, src_buf);
   if(got_src <= 0 && InpSourceBufferIndex != 0)
      got_src = CopyBuffer(g_source_handle, 0, 0, rates_total, src_buf);

   int bars_available = (got_src > 0) ? MathMin(rates_total, got_src) : 0;
   if(bars_available < (InpSlopeLen + 3))
      return(prev_calculated);

   double ema_abs_p[];
   double ema_abs_c[];
   if(InpCalcMode == MODIF_ANGULAR_LEGACY)
     {
      if(ArrayResize(ema_abs_p, bars_available) != bars_available ||
         ArrayResize(ema_abs_c, bars_available) != bars_available)
         return(prev_calculated);
      ArraySetAsSeries(ema_abs_p, true);
      ArraySetAsSeries(ema_abs_c, true);
     }

   const double alpha_norm = 2.0 / (InpNormEmaLen + 1.0);
   const double alpha_mod  = 2.0 / (InpModifSmoothLen + 1.0);
   const double eps = 1e-9;

   for(int i = bars_available - 1; i >= 0; --i)
     {
      price_raw[i] = GetAppliedPrice(i, open, high, low, close);

      if(i < got_src && src_buf[i] != EMPTY_VALUE && MathIsValidNumber(src_buf[i]))
         g_src_work[i] = src_buf[i];
      else if(i < bars_available - 1)
         g_src_work[i] = g_src_work[i + 1];
      else
         g_src_work[i] = EMPTY_VALUE;

      g_modif[i] = EMPTY_VALUE;
      g_cross_up[i] = EMPTY_VALUE;
      g_cross_down[i] = EMPTY_VALUE;

      if(InpCalcMode == MODIF_ANGULAR_LEGACY)
        {
         double adp = 0.0;
         double adc = 0.0;
         if(i + 1 < bars_available)
           {
            if(MathIsValidNumber(price_raw[i]) && MathIsValidNumber(price_raw[i + 1]))
               adp = MathAbs(price_raw[i] - price_raw[i + 1]);
            if(g_src_work[i] != EMPTY_VALUE && g_src_work[i + 1] != EMPTY_VALUE &&
               MathIsValidNumber(g_src_work[i]) && MathIsValidNumber(g_src_work[i + 1]))
               adc = MathAbs(g_src_work[i] - g_src_work[i + 1]);
           }

         if(i == bars_available - 1)
           {
            ema_abs_p[i] = adp;
            ema_abs_c[i] = adc;
           }
         else
           {
            ema_abs_p[i] = alpha_norm * adp + (1.0 - alpha_norm) * ema_abs_p[i + 1];
            ema_abs_c[i] = alpha_norm * adc + (1.0 - alpha_norm) * ema_abs_c[i + 1];
           }
        }
     }

   for(int i = rates_total - 1; i >= bars_available; --i)
     {
      g_src_work[i] = EMPTY_VALUE;
      g_modif[i] = EMPTY_VALUE;
      g_cross_up[i] = EMPTY_VALUE;
      g_cross_down[i] = EMPTY_VALUE;
     }

   int start_i = bars_available - InpSlopeLen - 1;
   int stop_i = 0;
   if(InpUseClosedBarOnly)
      stop_i = 1;

   for(int i = start_i; i >= stop_i; --i)
     {
      if(!MathIsValidNumber(price_raw[i]) || g_src_work[i] == EMPTY_VALUE || !MathIsValidNumber(g_src_work[i]))
         continue;
      if(i + InpSlopeLen >= bars_available)
         continue;
      if(!MathIsValidNumber(price_raw[i + InpSlopeLen]) ||
         g_src_work[i + InpSlopeLen] == EMPTY_VALUE ||
         !MathIsValidNumber(g_src_work[i + InpSlopeLen]))
         continue;

      const double slope_p = price_raw[i] - price_raw[i + InpSlopeLen];
      const double slope_c = g_src_work[i] - g_src_work[i + InpSlopeLen];
      double raw_modif = 0.0;

      if(InpCalcMode == MODIF_SIMPLE_RATIO)
        {
         const double rp = slope_p / (MathAbs(price_raw[i + InpSlopeLen]) + eps);
         const double rc = slope_c / (MathAbs(g_src_work[i + InpSlopeLen]) + eps);
         const double ap = MathAbs(rp);
         const double ac = MathAbs(rc);
         if(ap < eps && ac < eps)
            raw_modif = 0.0;
         else
           {
            const double sgn = ((rp * rc) >= 0.0 ? 1.0 : -1.0);
            const double sim = (2.0 * MathMin(ap, ac)) / (ap + ac + eps);
            raw_modif = 100.0 * sgn * sim;
           }
        }
      else
        {
         const double sp = slope_p / (eps + ema_abs_p[i]);
         const double sc = slope_c / (eps + ema_abs_c[i]);
         const double ap = MathArctan(sp);
         const double ac = MathArctan(sc);
         const double dtheta = WrapPi(ap - ac);
         const double align = MathCos(dtheta); // [-1,1]
         const double mratio = 1.0 - MathAbs(MathAbs(sp) - MathAbs(sc)) / (MathAbs(sp) + MathAbs(sc) + eps);
         const double mratio_clamped = Clamp(mratio, 0.0, 1.0);
         raw_modif = (0.75 * align + 0.25 * (2.0 * mratio_clamped - 1.0)) * 100.0;
        }

      if(i == bars_available - InpSlopeLen - 1 || g_modif[i + 1] == EMPTY_VALUE || !MathIsValidNumber(g_modif[i + 1]))
         g_modif[i] = raw_modif;
      else
         g_modif[i] = alpha_mod * raw_modif + (1.0 - alpha_mod) * g_modif[i + 1];

      if(i + 1 < bars_available && g_modif[i + 1] != EMPTY_VALUE && MathIsValidNumber(g_modif[i + 1]))
        {
         if(g_modif[i + 1] <= 0.0 && g_modif[i] > 0.0 && MathAbs(g_modif[i]) >= InpCrossThreshold)
            g_cross_up[i] = g_modif[i];
         else if(g_modif[i + 1] >= 0.0 && g_modif[i] < 0.0 && MathAbs(g_modif[i]) >= InpCrossThreshold)
            g_cross_down[i] = g_modif[i];
        }
     }

   if(InpUseClosedBarOnly)
     {
      g_modif[0] = EMPTY_VALUE;
      g_cross_up[0] = EMPTY_VALUE;
      g_cross_down[0] = EMPTY_VALUE;
     }

   double modif_now = EMPTY_VALUE;
   if(InpUseClosedBarOnly)
      modif_now = g_modif[1];
   else
      modif_now = g_modif[0];
   if(modif_now == EMPTY_VALUE || !MathIsValidNumber(modif_now))
      modif_now = 0.0;
   UpdateInfoLabel(modif_now);

   return(rates_total);
  }
//+------------------------------------------------------------------+
