#pragma once
#include <stdint.h>
#define VIDEO_BASE 0xf8100000u
#define VIDEO_VERSION 0x034u
#define VIDEO_CAPS 0x038u
#define VIDEO_R_SHADOW 0x040u
#define VIDEO_G_SHADOW 0x044u
#define VIDEO_B_SHADOW 0x048u
#define VIDEO_TONE_SHADOW 0x04cu
#define VIDEO_CFG_APPLY 0x050u
#define VIDEO_CFG_STATUS 0x054u
#define VIDEO_CAP_ACTIVE_SEQ 0x058u
#define VIDEO_DISP_ACTIVE_SEQ 0x05cu
#define VIDEO_R_ACTIVE 0x060u
#define VIDEO_G_ACTIVE 0x064u
#define VIDEO_B_ACTIVE 0x068u
#define VIDEO_LIFT_SHADOW 0x080u
#define VIDEO_STATS_SEQ 0x0c0u
#define VIDEO_Y_SUM 0x0c4u
#define VIDEO_TIME_LO 0x0c8u
#define VIDEO_TIME_HI 0x0ccu
#define VIDEO_FLAGS 0x0d0u
#define VIDEO_AE_METER 0x0d4u
#define VIDEO_FRAME_ID 0x0d8u
#define VIDEO_STATS_CFG 0x0dcu
#define VIDEO_SENSOR_FRAME 0x0e0u
#define VIDEO_SAMPLE_COUNT 0x0e4u
#define VIDEO_HOT_COUNT 0x0e8u
#define VIDEO_SOURCE 0x0ecu
#define VIDEO_UI_SHADOW 0x130u   /* {selection[1:0], compare_enable}; applied by VIDEO_CFG_APPLY bit1 */
#define VIDEO_FAULTS 0x140u
#define VIDEO_AWB_R_SUM 0x180u
#define VIDEO_AWB_G_SUM 0x184u
#define VIDEO_AWB_B_SUM 0x188u
#define VIDEO_AWB_COUNT 0x18cu
#define VIDEO_AWB_FILTER 0x190u
#define VIDEO_AWB_NEUTRAL 0x194u
#define VIDEO_AWB_TOTAL 0x1a0u
#define VIDEO_REQUIRED_CAPS ((1u<<3)|(1u<<5)|(1u<<8))
uint32_t video_read(uint32_t offset);
void video_write(uint32_t offset,uint32_t value);
int video_probe(void);
int video_apply_gains(uint16_t r,uint16_t g,uint16_t b);
typedef struct {
  uint32_t seq,y_sum,samples,hot,r_sum,g_sum,b_sum,cells,total,flags,frame,cfg,source;
  uint64_t timestamp;
} video_stats_t;
int video_stats_read(video_stats_t *s);
