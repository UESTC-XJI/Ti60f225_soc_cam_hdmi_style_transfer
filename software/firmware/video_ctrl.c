#include "video_regs.h"
uint32_t video_read(uint32_t off) { return *(volatile uint32_t *)(VIDEO_BASE+off); }
void video_write(uint32_t off,uint32_t value) { *(volatile uint32_t *)(VIDEO_BASE+off)=value; }
int video_probe(void) {
  return video_read(0)==0x4f534431u && video_read(VIDEO_VERSION)==0x10000u &&
    (video_read(VIDEO_CAPS)&VIDEO_REQUIRED_CAPS)==VIDEO_REQUIRED_CAPS && video_read(VIDEO_SOURCE)==1 ? 0:-1;
}
int video_apply_gains(uint16_t r,uint16_t g,uint16_t b) {
  if(!r||!g||!b||(video_read(VIDEO_CFG_STATUS)&1))return -1;
  video_write(VIDEO_R_SHADOW,r);video_write(VIDEO_G_SHADOW,g);video_write(VIDEO_B_SHADOW,b);
  video_write(VIDEO_CFG_APPLY,1);return 0;
}
