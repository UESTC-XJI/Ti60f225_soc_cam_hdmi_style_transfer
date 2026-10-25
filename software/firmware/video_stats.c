#include "video_regs.h"
int video_stats_read(video_stats_t *s) {
  for(unsigned n=0;n<3;n++) {
    s->seq=video_read(VIDEO_STATS_SEQ);
    s->y_sum=video_read(VIDEO_Y_SUM);s->samples=video_read(VIDEO_SAMPLE_COUNT);s->hot=video_read(VIDEO_HOT_COUNT);
    s->r_sum=video_read(VIDEO_AWB_R_SUM);s->g_sum=video_read(VIDEO_AWB_G_SUM);s->b_sum=video_read(VIDEO_AWB_B_SUM);
    s->cells=video_read(VIDEO_AWB_COUNT);s->total=video_read(VIDEO_AWB_TOTAL);s->flags=video_read(VIDEO_FLAGS);
    s->frame=video_read(VIDEO_FRAME_ID);s->cfg=video_read(VIDEO_STATS_CFG);s->source=video_read(VIDEO_SOURCE);
    uint32_t lo=video_read(VIDEO_TIME_LO),hi=video_read(VIDEO_TIME_HI);
    s->timestamp=((uint64_t)hi<<32)|lo;
    if(s->seq==video_read(VIDEO_STATS_SEQ))return s->source==1?0:-2;
  }
  return -1;
}
