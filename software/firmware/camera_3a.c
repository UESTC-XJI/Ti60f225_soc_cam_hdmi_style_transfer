#include "camera_3a.h"
#include "soc_video_driver.h"
// Colour balance for the display path (measured 2026-10-25 with a 24-patch
// chart under room light). The Bayer RAW carries roughly twice as much green as
// red/blue, so neutral white needs R and B pulled well above G. The RTL reset
// default is 360/256/425, which leaves the picture visibly cyan on this sensor;
// these values override it once at boot. Retune with _calib_apb.py rather than
// recompiling: write 0x040/0x044/0x048 then 0x050=1 and read the capture.
/* Set to 1 to freeze exposure after the first AE update. The colour gains are
 * only meaningful for a fixed exposure: with AE running, lowering a gain just
 * makes AE stretch the exposure back, so the picture brightness stays put while
 * dynamic range shrinks. Calibrate gains with AE frozen. */
/* AE runs normally now. It was frozen while colour gains were being tuned by
 * hand; with the quantisation range fixed there is no need to pin exposure, and
 * a fixed exposure cannot adapt to a change of light. */
#define STYLE_AE_FREEZE 0

/* 2026-10-27：从校准值 520/290/520 退回 RTL 默认 360/256/425 做 A/B。
 * 依据：CAP_DEFAULT[15:0]/[31:16]/[47:32] = 360/256/425（video_apb_ctrl.sv:32）。
 * 当前 DDR 实测风格帧 B-R = +25.6（模型侧离线预测 +21.4，两者吻合），说明偏色
 * 主要来自网络对该场景的固有偏色；但这组校准值是否把输入色平衡推歪了尚未验证：
 * 520/520 是 R、B 同倍放大(×2.03) 而 G 只 ×1.13；默认是 R 1.41 / G 1.0 / B 1.66。
 * 先测默认值，两个都测完再定。 */
#define STYLE_R_GAIN 400u
#define STYLE_G_GAIN 256u
#define STYLE_B_GAIN 414u

#ifdef EFX_SAPPHIRE_BSP
#include "bsp.h"
#define THREE_A_HZ BSP_CLINT_HZ
#else
#define THREE_A_HZ 100000000u
#endif
/* VTS（帧长，单位**行**）。
 *
 * 2026-10-21 illum_20261021：曾调到 2500 行换更长积分时间（-> ~18fps）。
 * 2026-10-27 改回 1700：实测采集侧才是全系统瓶颈 —— 推理已从 50ms 压到 39ms，
 *   但 raw_frames 只有 17.86fps（= 2500 行 × 22.4µs），网络 32% 时间在空转。
 *   1700 行 -> ~25.6fps，正好与 39ms 的网络负载对齐（网络上限 25.6fps）。
 *   代价：进光量 0.67×，亮度 mean 约 106 -> 71（AE 会把曝光顶到 2*1700-11=3389 半行）。
 *   ⚠ 再往上（1460 行 = 30fps）需要网络先压到 ≤33ms，否则会持续 DROP。
 * ⚠ 单位陷阱：VTS 是**行**，而曝光寄存器是**半行**（上限 2*VTS-11）。
 *   日志里两者并排打印会让人误以为"曝光超帧长"，见 camera_3a_log 处的注释。 */
/* 2026-10-28：1900 -> 1457 = 1080p 原生 30 fps（手册规格 1080p@30/60fps）。
 *   帧周期 1457 x 22.9us = 33.4 ms；推理实测 26 ms => 余量 7.4 ms（很充裕，
 *   历史上余量 1.8ms 就会持续丢帧，所以 7.4 是安全的）。
 *   环境不暗，曝光只用到 ~900 行（上限 2*1457-11 = 2903 半行 = 1451 行），
 *   不需要为了长曝光牺牲帧率。
 *   ⚠ VTS 是**行**，曝光寄存器是**半行**（日志现在分列 expL/expH 避免再误判）。 */
#define CAMERA_VTS_OVERRIDE 1457u
volatile uint32_t app_awb_mode=AWB_AUTO;
camera_3a_t app_3a;
static int advanced(uint32_t now,uint32_t old,uint32_t frames) { return (int32_t)(now-old)>=(int32_t)frames; }
int camera_3a_init(camera_3a_t *s,uint64_t now) {
  for(unsigned i=0;i<sizeof(*s);i++)((volatile unsigned char *)s)[i]=0;
  s->last_stats_time=now;
  if(video_probe())return -1;
  uint8_t h,l,a,b,c,delay;
  if(camera_verify_id()||camera_reg_read(0x320e,&h)||camera_reg_read(0x320f,&l)||
    camera_reg_read(0x3e00,&a)||camera_reg_read(0x3e01,&b)||camera_reg_read(0x3e02,&c)||
    camera_reg_read(0x3802,&delay)) {
    s->status=THREE_A_BUS_ERROR;s->errors++;return -2;
  }
  s->vts=((uint32_t)(h&0x7f)<<8)|l;
  if(s->vts<8)return -3;
  /* Write the longer VTS. The readback right after the group-hold release can
   * still return the old value, so the exposure ceiling follows what we wrote,
   * not what we read. A failed write keeps the sensor's own VTS. */
  {
    int error=camera_reg_write(0x3812,0x00);
    if(!error) error=camera_reg_write(0x320e,(uint8_t)((h&0x80)|(CAMERA_VTS_OVERRIDE>>8)));
    if(!error) error=camera_reg_write(0x320f,(uint8_t)(CAMERA_VTS_OVERRIDE&0xffu));
    int release=camera_reg_write(0x3812,0x30);
    if(error||release) {s->last_error=5;s->errors++;}
    else s->vts=CAMERA_VTS_OVERRIDE;
  }
  s->maximum=2*s->vts-11;s->exposure=((uint32_t)(a&15)<<12)|((uint32_t)b<<4)|(c>>4);
  s->confirm_frames=3u+(delay&3u);
  /* Apply the calibrated colour balance once. AWB cannot do this on this build:
   * its statistics block (0x180..) is absent, so camera_awb_target always bails
   * on zero sums and the gains never move off the RTL reset default. */
  video_apply_gains(STYLE_R_GAIN,STYLE_G_GAIN,STYLE_B_GAIN);
  s->last_seq=video_read(VIDEO_STATS_SEQ);s->have_seq=1;
  s->enabled=1;s->status=THREE_A_READY;return 0;
}
static int set_exposure(camera_3a_t *s,uint32_t value) {
  uint8_t a,b,c;
  if(camera_reg_read(0x3e00,&a)||camera_reg_read(0x3e01,&b)||camera_reg_read(0x3e02,&c))return -1;
  int error=camera_reg_write(0x3812,0);
  if(!error) error=camera_reg_write(0x3e00,(a&0xf0)|((value>>12)&15));
  if(!error) error=camera_reg_write(0x3e01,(value>>4)&255);
  if(!error) error=camera_reg_write(0x3e02,(c&15)|((value&15)<<4));
  // Always try release, even after failed hold or field write.
  int release=camera_reg_write(0x3812,0x30);
  if(error||release)return -1;
  s->exposure_reserved=((uint32_t)(a&0xf0)<<8)|(c&15);
  return 0;
}
static int confirm_exposure(camera_3a_t *s) {
  uint8_t a,b,c;
  if(camera_reg_read(0x3e00,&a)||camera_reg_read(0x3e01,&b)||camera_reg_read(0x3e02,&c))return 2;
  s->readback_exposure=((uint32_t)(a&15)<<12)|((uint32_t)b<<4)|(c>>4);
  return s->readback_exposure==s->pending_exposure&&
    (((uint32_t)(a&0xf0)<<8)|(c&15))==s->exposure_reserved?0:3;
}
void camera_3a_service(camera_3a_t *s,uint64_t now) {
  if(!s->enabled)return;
  if(video_read(VIDEO_FLAGS)&0x26u) {s->status=THREE_A_CAPTURE_FAULT;s->enabled=0;return;}
  if(now-s->last_stats_time>THREE_A_HZ) {s->status=THREE_A_NO_STATS;s->queued_exposure=0;}
  if(s->waiting_exposure&&now-s->wait_start>THREE_A_HZ*2ull) {
    s->last_error=4;s->status=THREE_A_CONFIG_TIMEOUT;s->enabled=0;s->errors++;return;
  }
  if(s->queued_exposure) {
    uint32_t sensor=video_read(VIDEO_SENSOR_FRAME);
    if(sensor==s->queue_sensor)return;
    uint32_t target=s->queued_exposure;s->queued_exposure=0;
    if(set_exposure(s,target)) {s->last_error=1;s->errors++;s->enabled=0;s->status=THREE_A_BUS_ERROR;return;}
    s->pending_exposure=target;s->write_sensor=video_read(VIDEO_SENSOR_FRAME);
    s->write_capture=video_read(VIDEO_FRAME_ID);s->waiting_exposure=1;
    s->wait_start=now;s->status=THREE_A_EXPOSURE_WAIT;return;
  }
  if(s->waiting_gain) {
    if(video_read(VIDEO_CFG_STATUS)&1) {
      if(now-s->wait_start>THREE_A_HZ*2ull){s->status=THREE_A_CONFIG_TIMEOUT;s->enabled=0;s->errors++;}
      return;
    }
    if(video_read(VIDEO_CAP_ACTIVE_SEQ)!=s->wanted_cfg||video_read(VIDEO_R_ACTIVE)!=s->expected_r||
      video_read(VIDEO_B_ACTIVE)!=s->expected_b||video_read(VIDEO_G_ACTIVE)!=s->expected_g) {
      /* 2026-10-27 修：这里原来写死 `!=256`，而实际下发的是 STYLE_G_GAIN。
       * 当前 G=256 时侥幸通过；一旦有人改 G（旧的 290 就是），这个校验永远失败，
       * 3A 会把 enabled 清 0 且没有任何重新使能路径（除相机重连）= 永久停摆。
       * 现在改成与 expected_r/expected_b 对称的 expected_g。 */
      s->status=THREE_A_CONFIG_TIMEOUT;s->enabled=0;s->errors++;return;
    }
  }
  video_stats_t v;
  if(video_stats_read(&v))return;
  /* 2026-10-27: 恢复高光保护。此前这里写死 v.hot=0，把 camera_ae_goal() 的
   * "高光越多、目标越低" 整条通路废掉了（goal 恒 128）。
   * 为什么当初要废掉它：RTL 侧 st_hot 位段错了（video_apb_ctrl.sv 原为
   * ae_rx[73:52]，22 位塞进 21 位），实际得到 {hot[19:0], n[20]}，
   * 即 ≈2×hot+1 —— 不是"一半"，是"两倍"。于是 5.3% 热就贴底、
   * 50~85% 热时越界丢帧导致 AE 停摆、>85% 回绕成非单调。
   * 该位段已在 RTL 侧修正为 [73:53]，此处才敢打开。 */
  if(v.hot>v.samples) { v.hot=0; s->errors++; }   /* 防御：位段若再出错，不要静默 */
  if(s->have_seq&&v.seq==s->last_seq) {
    if(now-s->last_stats_time>THREE_A_HZ) s->status=THREE_A_NO_STATS;
    return;
  }
  s->last_seq=v.seq;s->have_seq=1;s->last_frame=v.frame;
  if(!(v.flags&1)||!v.samples||v.hot>v.samples||v.y_sum>(uint64_t)v.samples*255u||
    (v.flags&0x26)||v.cfg!=video_read(VIDEO_CAP_ACTIVE_SEQ))return;
  s->last_stats_time=now;
  if(s->waiting_gain) { if(v.cfg!=s->wanted_cfg)return;s->waiting_gain=0;s->awb_updates++; }
  if(s->waiting_exposure) {
    // Group Hold delay (3802[1:0]) plus a conservative N+2 guard. Readback
    // belongs here, after application; an immediate read can still be old.
    if(!advanced(video_read(VIDEO_SENSOR_FRAME),s->write_sensor,s->confirm_frames)||
       !advanced(v.frame,s->write_capture,s->confirm_frames))return;
    int error=confirm_exposure(s);
    if(error) {s->last_error=(uint32_t)error;s->errors++;s->enabled=0;s->status=THREE_A_BUS_ERROR;return;}
    s->exposure=s->pending_exposure;s->pending_exposure=0;s->ae_updates++;
    s->waiting_exposure=0;
  }
  s->mean=v.y_sum/v.samples;s->high_permille=(uint32_t)((uint64_t)v.hot*1000/v.samples);s->status=THREE_A_READY;
  s->ae_goal=camera_ae_goal(s->high_permille);
#if STYLE_AE_FREEZE
  /* Freeze: report stats but never move the exposure again. */
  s->ae_held=1;
  return;
#endif
  uint32_t target=camera_ae_target(s->exposure,s->maximum,s->mean,s->high_permille);
  uint32_t error=s->mean>s->ae_goal?s->mean-s->ae_goal:s->ae_goal-s->mean;
  if(target==s->exposure) {
    s->ae_held=1;s->ae_streak=0;s->ae_direction=0;
  } else if(s->exposure>=4&&s->exposure<=s->maximum&&error<24) {
    // Enter hold within +/-4; leave only outside +/-8. Three consecutive
    // settled snapshots in one direction reject isolated/flickering errors.
    uint32_t direction=s->mean<s->ae_goal?1u:2u;
    if(s->ae_held&&error<=8) {s->ae_streak=0;s->ae_direction=0;target=s->exposure;}
    else {
      s->ae_streak=direction==s->ae_direction?s->ae_streak+1u:1u;
      s->ae_direction=direction;
      if(s->ae_streak<3)target=s->exposure;
    }
  }
  if(target!=s->exposure) {
    s->ae_held=0;s->ae_streak=0;s->ae_direction=0;
    s->queued_exposure=target;s->queue_sensor=video_read(VIDEO_SENSOR_FRAME);
    s->wait_start=now;s->status=THREE_A_EXPOSURE_WAIT;return;
  }
  uint16_t r=(uint16_t)video_read(VIDEO_R_ACTIVE),b=(uint16_t)video_read(VIDEO_B_ACTIVE),nr=r,nb=b;
  if(app_awb_mode==AWB_LOCK)return;
  if(app_awb_mode==AWB_FIXED) {nr=STYLE_R_GAIN;nb=STYLE_B_GAIN;if(r==nr&&b==nb)return;}
  else {
    if(app_awb_mode!=AWB_AUTO||(s->have_awb_frame&&!advanced(v.frame,s->last_awb_frame,4))||
      !camera_awb_target(&v,r,b,&nr,&nb))return;
  }
  if(video_read(VIDEO_CFG_STATUS)&1)return;
  s->wanted_cfg=video_read(VIDEO_CAP_ACTIVE_SEQ)+1u;
  if(video_apply_gains(nr,STYLE_G_GAIN,nb))return;
  s->expected_r=nr;s->expected_b=nb;s->expected_g=STYLE_G_GAIN;s->waiting_gain=1;s->wait_start=now;
  s->last_awb_frame=v.frame;s->have_awb_frame=1;s->status=THREE_A_GAIN_WAIT;
}

#ifdef EFX_SAPPHIRE_BSP
static char *decimal(char *p,uint32_t v) {
  char digits[10];unsigned n=0;
  do{digits[n++]=(char)('0'+v%10);v/=10;}while(v);
  while(n)*p++=digits[--n];
  return p;
}
static char *label(char *p,const char *text,uint32_t v) {
  while(*text)*p++=*text++;
  return decimal(p,v);
}
void camera_3a_log(const camera_3a_t *s) {
  char text[256],*p=text;
  // ⚠ 单位陷阱：exp 是**半行**、vts 是**行**。以前两者并排打印，看日志的人
  //   （包括我自己，2026-10-27）会以为 "exp 4989 > vts 2500 = 曝光超帧长"，
  //   实际上 4989 半行 = 2494.5 行 < 2500 行。现在把 exp 换成行数并标出单位。
  p=label(p,"3A state ",s->status);
  p=label(p," expL ",s->exposure/2);          // 行
  p=label(p," expH ",s->exposure%2);          // 半行的奇偶（0 或 1）
  p=label(p," vts ",s->vts);                  // 行
  p=label(p," mean ",s->mean);p=label(p," hot ",s->high_permille);
  p=label(p," goal ",s->ae_goal);p=label(p," hold ",s->ae_held);
  p=label(p," R ",video_read(VIDEO_R_ACTIVE));p=label(p," B ",video_read(VIDEO_B_ACTIVE));
  p=label(p," AE ",s->ae_updates);p=label(p," AWB ",s->awb_updates);
  p=label(p," code ",s->last_error);p=label(p," req ",s->pending_exposure);p=label(p," rb ",s->readback_exposure);
  p=label(p," err ",s->errors);*p++='\r';*p++='\n';*p=0;
  uart_writeStr(BSP_UART_TERMINAL,text);
}
#else
void camera_3a_log(const camera_3a_t *s){(void)s;}
#endif
