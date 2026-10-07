// Sapphire firmware driver for the APB OSD block and camera I2C sequence.
// The MMIO addresses match settings.json: APB slave 0 is 0xf8100000.
#include <stdint.h>
#include <stddef.h>
#include "camera_init_table.h"

#ifdef EFX_SAPPHIRE_BSP
#include "bsp.h"
#include "i2c.h"
#endif

#ifdef SOC_DRIVER_HOST
extern volatile uint32_t soc_osd_mmio[10];
#define SOC_OSD_BASE ((uintptr_t)&soc_osd_mmio[0])
#elif !defined(SOC_OSD_BASE)
#define SOC_OSD_BASE 0xf8100000u
#endif
#define OSD_ID       0x00u
#define OSD_ENABLE   0x04u
#define OSD_X        0x08u
#define OSD_Y        0x0cu
#define OSD_COLOR    0x10u
#define OSD_CHARADDR 0x14u
#define OSD_CHARDATA 0x18u
#define OSD_COMMIT   0x1cu
#define OSD_STATUS   0x20u
#define OSD_STATUS2  0x24u
#define CAMERA_SENSOR_ID 0xcd6bu

static inline void osd_write(uint32_t off,uint32_t value) {
  *(volatile uint32_t *)(SOC_OSD_BASE+off)=value;
#ifdef SOC_DRIVER_HOST
  if(off==OSD_COMMIT) soc_osd_mmio[OSD_STATUS/4]^=1u;
#endif
}
static inline uint32_t osd_read(uint32_t off) { return *(volatile uint32_t *)(SOC_OSD_BASE+off); }

// Board BSP supplies these three primitives. Keeping them as weak symbols
// lets the host protocol test link without a RISC-V BSP.
#ifdef EFX_SAPPHIRE_BSP
static void sapphire_delay_us(uint32_t us) { bsp_uDelay(us); }
static int sapphire_i2c_write16(uint16_t reg,uint8_t value) {
  u8 data=value;
  i2c_writeData_w(SYSTEM_I2C_0_IO_CTRL, 0x60, reg, &data, 1);
  return 0;
}
static int sapphire_i2c_read16(uint16_t reg,uint8_t *value) {
  u8 data=0;
  i2c_readData_w(SYSTEM_I2C_0_IO_CTRL, 0x60, reg, &data, 1);
  if(value) *value=data;
  return 0;
}
static void sapphire_uart_log(const char *s) { while(*s) bsp_putChar(*s++); }
#else
__attribute__((weak)) void sapphire_delay_us(uint32_t us) { (void)us; }
__attribute__((weak)) int sapphire_i2c_write16(uint16_t reg,uint8_t value) { (void)reg;(void)value; return 0; }
__attribute__((weak)) int sapphire_i2c_read16(uint16_t reg,uint8_t *value) { (void)reg; if(value)*value=0; return 0; }
__attribute__((weak)) void sapphire_uart_log(const char *s) { (void)s; }
#endif

static uint32_t osd_status(void) { return osd_read(OSD_STATUS); }
static int osd_wait_ack(uint32_t old_ack) {
  for(uint32_t timeout=0;timeout<1000000u;timeout++) {
    uint32_t s=osd_status();
    if(((s&1u)!=0u) != (old_ack!=0u) && !(s&(1u<<2))) return 0;
  }
  return -1;
}

int osd_write_string(const char *text) {
  uint32_t before=osd_status(), page=((before>>1)&1u)^1u;
  osd_write(OSD_ENABLE,1); osd_write(OSD_X,16); osd_write(OSD_Y,16); osd_write(OSD_COLOR,0x20ff40);
  for(uint32_t i=0;text[i] && i<80;i++) { osd_write(OSD_CHARADDR,(page<<7)|i); osd_write(OSD_CHARDATA,(uint8_t)text[i]); }
  osd_write(OSD_CHARADDR,page<<7); osd_write(OSD_COMMIT,1);
  return osd_wait_ack(before&1u);
}

int camera_read_id(uint16_t *id) {
  uint8_t hi=0,lo=0;
  if(sapphire_i2c_read16(0x3107,&hi) || sapphire_i2c_read16(0x3108,&lo)) return -1;
  *id=((uint16_t)hi<<8)|lo; return 0;
}

int camera_verify_id(void) {
  uint16_t id=0;
  return camera_read_id(&id) || id!=CAMERA_SENSOR_ID ? -1 : 0;
}

int camera_init_cpu(void) {
  if(camera_verify_id()) return -3;
  for(size_t i=0;i<CAMERA_INIT_COUNT;i++) {
    const camera_init_entry_t *e=&camera_init_table[i];
    if(sapphire_i2c_write16(e->reg,e->value)) return -1;
    if(e->delay_us) sapphire_delay_us(e->delay_us);
    if(e->readback) { uint8_t got=0; if(sapphire_i2c_read16(e->reg,&got) || got!=e->value) return -2; }
  }
  return 0;
}

int camera_start(void) { return sapphire_i2c_write16(0x0100,1); }
int camera_stop(void) { return sapphire_i2c_write16(0x0100,0); }
int camera_recover(void) { if(camera_stop()) return -1; sapphire_delay_us(5000); return camera_init_cpu(); }

// Call once per second from the CLINT timer. The status layout is documented
// in osd_apb_regs.sv; FPS is read from real capture/display frame counters.
static char *put_dec(char *p,uint32_t v) {
  char tmp[10]; uint32_t n=0;
  do { tmp[n++]=(char)('0'+(v%10u)); v/=10u; } while(v && n<sizeof(tmp));
  while(n) *p++=tmp[--n];
  return p;
}
int osd_publish_metrics(void) {
  uint32_t s=osd_status(), s2=osd_read(OSD_STATUS2); char text[80],*p=text;
  uint32_t capture_fps=s2&0xffffu, display_fps=(s2>>16)&0xffffu;
  uint32_t drop=(s>>11)&0xffu, err=(s>>19)&0xffu;
  p[0]='F';p[1]='P';p[2]='S';p[3]=' ';p=put_dec(p+4,capture_fps);
  *p++=' ';*p++='D';*p++='I';*p++='S';*p++='P';*p++=' ';p=put_dec(p,display_fps);
  *p++=' ';*p++='D';*p++='R';*p++='O';*p++='P';*p++=' ';p=put_dec(p,drop);
  *p++=' ';*p++='E';*p++='R';*p++='R';*p++=' ';p=put_dec(p,err);*p=0;
  sapphire_uart_log(text); sapphire_uart_log("\n");
  return osd_write_string(text);
}
