#ifndef __COMPRESS_V25_DIAGNOSTICS_MQH__
#define __COMPRESS_V25_DIAGNOSTICS_MQH__

struct WaveDiagStats
  {
   bool   enabled;
   int    bars_available;
   int    runs_total;
   int    runs_selected;
   int    segments_total;
   int    waves_valid;
   int    peaks_marked;
   int    holes_marked;
   int    zero_marked;
   int    rejected_short_segment;
   int    rejected_low_amplitude;
   int    rejected_no_peak;
   int    rejected_slot_conflict;
   string marker_view_mode;
   string last_event;
  };

void WaveDiagReset(WaveDiagStats &stats,const bool enabled)
  {
   stats.enabled = enabled;
   stats.bars_available = 0;
   stats.runs_total = 0;
   stats.runs_selected = 0;
   stats.segments_total = 0;
   stats.waves_valid = 0;
   stats.peaks_marked = 0;
   stats.holes_marked = 0;
   stats.zero_marked = 0;
   stats.rejected_short_segment = 0;
   stats.rejected_low_amplitude = 0;
   stats.rejected_no_peak = 0;
   stats.rejected_slot_conflict = 0;
   stats.marker_view_mode = "ALL";
   stats.last_event = "diag: idle";
  }

void WaveDiagSetLastEvent(WaveDiagStats &stats,const string message)
  {
   if(!stats.enabled)
      return;
   stats.last_event = message;
  }

void WaveDiagCountSlotConflict(WaveDiagStats &stats,const string tag,const int index)
  {
   if(!stats.enabled)
      return;
   ++stats.rejected_slot_conflict;
   stats.last_event = StringFormat("slot_conflict %s idx=%d",tag,index);
  }

void WaveDiagClearOverlay(const long chart_id,
                          const string prefix)
  {
   ObjectDelete(chart_id,prefix + "diag_label");
  }

void WaveDiagRenderOverlay(const long chart_id,
                           const string prefix,
                           const string indicator_shortname,
                           const WaveDiagStats &stats,
                           const color ok_color,
                           const color warn_color,
                           const color off_color)
  {
   string label_name = prefix + "diag_label";

   if(!stats.enabled)
     {
      ObjectDelete(chart_id,label_name);
      return;
     }

   int wnd = ChartWindowFind(chart_id,indicator_shortname);
   if(wnd < 0)
      wnd = 0;

   if(ObjectFind(chart_id,label_name) >= 0)
     {
      if((ENUM_OBJECT)ObjectGetInteger(chart_id,label_name,OBJPROP_TYPE) != OBJ_LABEL)
         ObjectDelete(chart_id,label_name);
     }

   if(ObjectFind(chart_id,label_name) < 0)
     {
      if(!ObjectCreate(chart_id,label_name,OBJ_LABEL,wnd,0,0))
         return;
     }

   string text =
      StringFormat("DIAG ON | mode=%s | bars=%d runs=%d sel=%d seg=%d waves=%d\n"
                   "marked: peak=%d hole=%d zero=%d | reject: short=%d amp=%d no_peak=%d slot=%d\n"
                   "%s",
                   stats.marker_view_mode,
                   stats.bars_available,
                   stats.runs_total,
                   stats.runs_selected,
                   stats.segments_total,
                   stats.waves_valid,
                   stats.peaks_marked,
                   stats.holes_marked,
                   stats.zero_marked,
                   stats.rejected_short_segment,
                   stats.rejected_low_amplitude,
                   stats.rejected_no_peak,
                   stats.rejected_slot_conflict,
                   stats.last_event);

   color label_color = ok_color;
   if(stats.waves_valid <= 0)
      label_color = warn_color;

   ObjectSetString(chart_id,label_name,OBJPROP_TEXT,text);
   ObjectSetString(chart_id,label_name,OBJPROP_FONT,"Consolas");
   ObjectSetInteger(chart_id,label_name,OBJPROP_FONTSIZE,12);
   ObjectSetInteger(chart_id,label_name,OBJPROP_COLOR,label_color);
   ObjectSetInteger(chart_id,label_name,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
   ObjectSetInteger(chart_id,label_name,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(chart_id,label_name,OBJPROP_XDISTANCE,16);
   ObjectSetInteger(chart_id,label_name,OBJPROP_YDISTANCE,20);
   ObjectSetInteger(chart_id,label_name,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(chart_id,label_name,OBJPROP_SELECTED,false);
   ObjectSetInteger(chart_id,label_name,OBJPROP_HIDDEN,true);

   if(stats.bars_available <= 0)
      ObjectSetInteger(chart_id,label_name,OBJPROP_COLOR,off_color);
  }

#endif // __COMPRESS_V25_DIAGNOSTICS_MQH__
