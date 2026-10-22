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
int video_hist_poll(video_hist_t *h) {
  if(!(video_read(VIDEO_CAPS)&(1u<<6)))return -1;
  uint32_t status=video_read(VIDEO_HIST_STATUS);
  if(status&4){h->state=0;return -2;}
  if(h->state==0) {
    if(status&1)return 0;
    if(status&2)video_write(VIDEO_HIST_CMD,2);
    video_write(VIDEO_HIST_CMD,1);h->state=1;h->index=0;return 0;
  }
  if(h->state==1) {
    if(!(status&2))return 0;
    h->sequence=video_read(VIDEO_HIST_SEQ);h->state=2;
  }
  for(unsigned budget=0;budget<4&&h->index<78;budget++,h->index++) {
    if(h->index<14) {
      video_write(VIDEO_HIST_META_INDEX,h->index);h->meta[h->index]=video_read(VIDEO_HIST_META_DATA);
    }else {
      video_write(VIDEO_HIST_INDEX,h->index-14);h->bins[h->index-14]=video_read(VIDEO_HIST_DATA);
    }
  }
  if(h->index<78)return 0;
  uint32_t sum=0;for(unsigned i=0;i<64;i++)sum+=h->bins[i];
  int valid=sum==h->meta[1]&&h->meta[13]==1&&(h->meta[8]&1)&&h->sequence==video_read(VIDEO_HIST_SEQ);
  video_write(VIDEO_HIST_CMD,2);h->state=0;return valid?1:-3;
}
