#pragma once
#include "video_regs.h"
enum { AWB_FIXED=0,AWB_AUTO=1,AWB_LOCK=2 };
enum { THREE_A_OFF=0,THREE_A_READY=1,THREE_A_EXPOSURE_WAIT=2,THREE_A_GAIN_WAIT=3,
  THREE_A_NO_STATS=4,THREE_A_BUS_ERROR=5,THREE_A_CONFIG_TIMEOUT=6,THREE_A_CAPTURE_FAULT=7 };
typedef struct {
  uint32_t exposure,maximum,vts,last_seq,last_frame,write_sensor,write_capture,wanted_cfg;
  uint32_t mean,high_permille,ae_updates,awb_updates,errors,status,have_seq,enabled;
  /* expected_g：2026-10-27 新增。原 :109 把 G 通道的期望值写死 256，
   * 而实际下发的是 STYLE_G_GAIN —— 一旦两者不等（旧的 290 就是），
   * gain 回读校验永远失败 ⇒ 3A 永久停摆且无重新使能路径。
   * 现在与 expected_r / expected_b 对称。 */
  uint32_t waiting_exposure,waiting_gain,last_awb_frame,have_awb_frame,expected_r,expected_b,expected_g;
  uint32_t queued_exposure,queue_sensor;
  uint32_t pending_exposure,exposure_reserved,confirm_frames,last_error,readback_exposure;
  uint32_t ae_goal,ae_held,ae_direction,ae_streak;
  uint64_t last_stats_time,wait_start;
} camera_3a_t;
extern volatile uint32_t app_awb_mode;
extern camera_3a_t app_3a;
int camera_3a_init(camera_3a_t *s,uint64_t now);
void camera_3a_service(camera_3a_t *s,uint64_t now);
uint32_t camera_ae_target(uint32_t exposure,uint32_t maximum,uint32_t mean,uint32_t high_permille);
uint32_t camera_ae_goal(uint32_t high_permille);
int camera_awb_target(const video_stats_t *s,uint16_t active_r,uint16_t active_b,uint16_t *r,uint16_t *b);

void camera_3a_log(const camera_3a_t *s);
