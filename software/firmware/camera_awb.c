#include "camera_3a.h"
static uint16_t smooth(uint16_t current,uint64_t target) {
  if(target<128)target=128;
  if(target>1024)target=1024;
  int32_t delta=(int32_t)target-current;
  if(delta>=-3&&delta<=3)return current;
  delta=delta>0?(delta+2)/4:(delta-2)/4;
  if(delta>16)delta=16;
  if(delta< -16)delta= -16;
  return (uint16_t)((int32_t)current+delta);
}
int camera_awb_target(const video_stats_t *s,uint16_t ar,uint16_t ab,uint16_t *r,uint16_t *b) {
  if(!(s->flags&16)||s->cells<64||s->cells>s->total||!s->total||
    (uint64_t)s->cells*1000u<(uint64_t)s->total*50u||!s->r_sum||!s->b_sum||!s->g_sum)return 0;
  // G_SUM contains both green samples. Rounded absolute RAW gain ratio.
  uint64_t rd=(uint64_t)s->r_sum*2,bd=(uint64_t)s->b_sum*2;
  *r=smooth(ar,((uint64_t)s->g_sum*256+rd/2)/rd);
  *b=smooth(ab,((uint64_t)s->g_sum*256+bd/2)/bd);
  return *r!=ar||*b!=ab;
}
