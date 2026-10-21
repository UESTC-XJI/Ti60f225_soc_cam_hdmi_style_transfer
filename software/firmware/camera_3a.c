#include "camera_3a.h"
#include "soc_video_driver.h"
#ifdef EFX_SAPPHIRE_BSP
#include "bsp.h"
#define THREE_A_HZ BSP_CLINT_HZ
#else
#define THREE_A_HZ 100000000u
#endif
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
  s->maximum=2*s->vts-11;s->exposure=((uint32_t)(a&15)<<12)|((uint32_t)b<<4)|(c>>4);
  s->confirm_frames=3u+(delay&3u);
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
      video_read(VIDEO_B_ACTIVE)!=s->expected_b||video_read(VIDEO_G_ACTIVE)!=256) {
      s->status=THREE_A_CONFIG_TIMEOUT;s->enabled=0;s->errors++;return;
    }
  }
  video_stats_t v;
  if(video_stats_read(&v))return;
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
  if(app_awb_mode==AWB_FIXED) {nr=0x168;nb=0x1a9;if(r==nr&&b==nb)return;}
  else {
    if(app_awb_mode!=AWB_AUTO||(s->have_awb_frame&&!advanced(v.frame,s->last_awb_frame,4))||
      !camera_awb_target(&v,r,b,&nr,&nb))return;
  }
  if(video_read(VIDEO_CFG_STATUS)&1)return;
  s->wanted_cfg=video_read(VIDEO_CAP_ACTIVE_SEQ)+1u;
  if(video_apply_gains(nr,256,nb))return;
  s->expected_r=nr;s->expected_b=nb;s->waiting_gain=1;s->wait_start=now;
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
  p=label(p,"3A state ",s->status);p=label(p," exp ",s->exposure);p=label(p," vts ",s->vts);
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
