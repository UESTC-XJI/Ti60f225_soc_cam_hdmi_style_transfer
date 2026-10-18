// Sapphire firmware driver for the APB OSD block and camera I2C sequence.
// The MMIO addresses match settings.json: APB slave 0 is 0xf8100000.
#include <stdint.h>
#include <stddef.h>
#include "camera_init_table.h"
#include "soc_video_driver.h"

#ifdef EFX_SAPPHIRE_BSP
#include "bsp.h"
#include "i2c.h"
#endif

#ifdef SOC_DRIVER_HOST
extern volatile uint32_t soc_osd_mmio[13];
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
#define OSD_VIDEO_READY 0x28u
#define OSD_RAW_FPS     0x2cu
#define OSD_RESIZE_FPS  0x30u
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
/* Bound every controller wait. Sapphire RX_ACK.VALID is read-to-clear;
 * writing LISTEN does not clear it and a stale valid ACK stalls the next ACK. */
static int i2c_wait_clear(uint32_t off,uint32_t mask,uint64_t start) {
  while(read_u32(SYSTEM_I2C_0_IO_CTRL+off)&mask) {
    if(clint_getTime(BSP_CLINT)-start>=BSP_CLINT_HZ/200u)return -2;
  }
  return 0;
}
static int i2c_start_checked(uint64_t start) {
  i2c_masterStart(SYSTEM_I2C_0_IO_CTRL);
  if(i2c_wait_clear(I2C_MASTER_STATUS,I2C_MASTER_START,start))return -2;
  return i2c_getMasterStatus(SYSTEM_I2C_0_IO_CTRL)&I2C_MASTER_START_DROPPED ? -3:0;
}
static int i2c_byte_checked(uint8_t byte,uint64_t start) {
  (void)read_u32(SYSTEM_I2C_0_IO_CTRL+I2C_RX_ACK);
  i2c_listenAck(SYSTEM_I2C_0_IO_CTRL);
  i2c_txByte(SYSTEM_I2C_0_IO_CTRL,byte);i2c_txNack(SYSTEM_I2C_0_IO_CTRL);
  if(i2c_wait_clear(I2C_TX_ACK,I2C_TX_VALID,start))return -2;
  uint32_t ack;
  do {
    ack=read_u32(SYSTEM_I2C_0_IO_CTRL+I2C_RX_ACK);
    if(clint_getTime(BSP_CLINT)-start>=BSP_CLINT_HZ/200u)return -2;
  }while(!(ack&I2C_RX_VALID));
  return ack&1u?-1:0;
}
static int i2c_stop_checked(int error) {
  uint64_t start=clint_getTime(BSP_CLINT);
  i2c_masterStop(SYSTEM_I2C_0_IO_CTRL);
  int stop=i2c_wait_clear(I2C_MASTER_STATUS,I2C_MASTER_STOP|I2C_MASTER_BUSY,start);
  if(stop||i2c_getMasterStatus(SYSTEM_I2C_0_IO_CTRL)&I2C_MASTER_STOP_DROPPED) {
    i2c_masterDrop(SYSTEM_I2C_0_IO_CTRL);return error?error:-2;
  }
  return error;
}
static int i2c_address_checked(uint16_t reg,uint64_t start) {
  int rc=i2c_start_checked(start);
  if(!rc)rc=i2c_byte_checked(0x60,start);
  if(!rc)rc=i2c_byte_checked((uint8_t)(reg>>8),start);
  if(!rc)rc=i2c_byte_checked((uint8_t)reg,start);
  return rc;
}
static int sapphire_i2c_write16(uint16_t reg,uint8_t value) {
  uint64_t start=clint_getTime(BSP_CLINT);
  int rc=i2c_address_checked(reg,start);
  if(!rc)rc=i2c_byte_checked(value,start);
  return i2c_stop_checked(rc);
}
static int sapphire_i2c_read16(uint16_t reg,uint8_t *value) {
  if(!value)return -1;
  uint64_t start=clint_getTime(BSP_CLINT);
  int rc=i2c_address_checked(reg,start);
  if(!rc)rc=i2c_start_checked(start);
  if(!rc)rc=i2c_byte_checked(0x61,start);
  uint8_t data=0;
  if(!rc) {
    /* The final master NACK is not a slave response. Do not latch it into
     * RX_ACK, where it would survive STOP and block a later transaction. */
    write_u32(0,SYSTEM_I2C_0_IO_CTRL+I2C_RX_ACK);
    i2c_txByte(SYSTEM_I2C_0_IO_CTRL,0xff);i2c_txNack(SYSTEM_I2C_0_IO_CTRL);
    rc=i2c_wait_clear(I2C_TX_ACK,I2C_TX_VALID,start);
    if(!rc)data=(uint8_t)i2c_rxData(SYSTEM_I2C_0_IO_CTRL);
  }
  rc=i2c_stop_checked(rc);if(!rc)*value=data;return rc;
}
static int sapphire_i2c_recover(void) {
  uint32_t status=i2c_getMasterStatus(SYSTEM_I2C_0_IO_CTRL);
  uint32_t lines=read_u32(SYSTEM_I2C_0_IO_CTRL+I2C_SLAVE_STATUS);
  if(!(status&(I2C_MASTER_BUSY|0xf0u|I2C_MASTER_START_DROPPED|I2C_MASTER_STOP_DROPPED|
               I2C_MASTER_RECOVER_DROPPED))&&
     (lines&6u)==6u)return 0;
  /* A debugger stop or timed-out transfer can leave the slave driving SDA.
   * Drain receive backpressure, drop the old transfer and clock bus recovery. */
  write_u32(0,SYSTEM_I2C_0_IO_CTRL+I2C_RX_ACK);
  write_u32(0,SYSTEM_I2C_0_IO_CTRL+I2C_RX_DATA);
  (void)read_u32(SYSTEM_I2C_0_IO_CTRL+I2C_RX_ACK);
  (void)read_u32(SYSTEM_I2C_0_IO_CTRL+I2C_RX_DATA);
  uint64_t start=clint_getTime(BSP_CLINT);
  i2c_masterDrop(SYSTEM_I2C_0_IO_CTRL);
  if(i2c_wait_clear(I2C_MASTER_STATUS,I2C_MASTER_DROP|I2C_MASTER_BUSY,start))return -2;
  start=clint_getTime(BSP_CLINT);
  i2c_masterRecover(SYSTEM_I2C_0_IO_CTRL);
  if(i2c_wait_clear(I2C_MASTER_STATUS,I2C_MASTER_RECOVER|I2C_MASTER_BUSY,start)||
     (i2c_getMasterStatus(SYSTEM_I2C_0_IO_CTRL)&I2C_MASTER_RECOVER_DROPPED)) {
    i2c_masterDrop(SYSTEM_I2C_0_IO_CTRL);return -2;
  }
  /* RECOVER emits STOP itself. A second STOP while idle stays pending in
   * this controller and would make every later recovery time out. */
  write_u32(I2C_MASTER_START_DROPPED|I2C_MASTER_STOP_DROPPED|I2C_MASTER_RECOVER_DROPPED,
            SYSTEM_I2C_0_IO_CTRL+I2C_MASTER_STATUS);
  return (read_u32(SYSTEM_I2C_0_IO_CTRL+I2C_SLAVE_STATUS)&6u)==6u?0:-2;
}
static void sapphire_uart_log(const char *s) { while(*s) bsp_putChar(*s++); }
#else
__attribute__((weak)) void sapphire_delay_us(uint32_t us) { (void)us; }
__attribute__((weak)) int sapphire_i2c_write16(uint16_t reg,uint8_t value) { (void)reg;(void)value; return 0; }
__attribute__((weak)) int sapphire_i2c_read16(uint16_t reg,uint8_t *value) { (void)reg; if(value)*value=0; return 0; }
static int sapphire_i2c_recover(void) {return 0;}
__attribute__((weak)) void sapphire_uart_log(const char *s) { (void)s; }
#endif

int camera_reg_read(uint16_t reg,uint8_t *value) {return sapphire_i2c_read16(reg,value);}
int camera_reg_write(uint16_t reg,uint8_t value) {return sapphire_i2c_write16(reg,value);}
static uint32_t osd_status(void) { return osd_read(OSD_STATUS); }
void osd_set_video_ready(uint32_t ready) { osd_write(OSD_VIDEO_READY,ready & 1u); }
static int osd_wait_ack(uint32_t old_ack) {
#ifdef EFX_SAPPHIRE_BSP
  uint64_t start=clint_getTime(BSP_CLINT);
  while(clint_getTime(BSP_CLINT)-start < BSP_CLINT_HZ/4u) {
#else
  for(uint32_t timeout=0;timeout<1000000u;timeout++) {
#endif
    uint32_t s=osd_status();
    if(((s&1u)!=0u) != (old_ack!=0u) && !(s&(1u<<2))) return 0;
  }
  return -1;
}

static uint32_t pending_ack;static int pending_osd;
int osd_poll(void) {
  if(!pending_osd)return 1;
  uint32_t status=osd_status();
  if((status&1u)!=pending_ack&&!(status&4u)){pending_osd=0;return 1;}
  return 0;
}
int osd_submit_string(const char *text) {
  uint32_t before=osd_status(), page=((before>>1)&1u)^1u;
  if(!text || (before&(1u<<2))) return -1;
  osd_write(OSD_ENABLE,1); osd_write(OSD_X,16); osd_write(OSD_Y,16); osd_write(OSD_COLOR,0x20ff40);
  uint32_t ended=0;
  for(uint32_t i=0;i<80;i++) {
    uint8_t ch=' ';
    if(!ended) { if(text[i]) ch=(uint8_t)text[i]; else ended=1; }
    osd_write(OSD_CHARADDR,(page<<7)|i); osd_write(OSD_CHARDATA,ch);
  }
  osd_write(OSD_CHARADDR,page<<7); osd_write(OSD_COMMIT,1);
  pending_ack=before&1u;pending_osd=1;return 0;
}
int osd_write_string(const char *text) {
  if(osd_submit_string(text))return -1;
  int rc=osd_wait_ack(pending_ack);if(!rc)pending_osd=0;return rc;
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
  if(sapphire_i2c_recover())return -4;
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
int camera_recover(void) { if(sapphire_i2c_recover())return -4; if(camera_stop()) return -1; sapphire_delay_us(5000); return camera_init_cpu(); }

// Call once per second from the CLINT timer. The status layout is documented
// in osd_apb_regs.sv; FPS is read from real capture/display frame counters.
static char *put_dec(char *p,uint32_t v) {
  char tmp[10]; uint32_t n=0;
  do { tmp[n++]=(char)('0'+(v%10u)); v/=10u; } while(v && n<sizeof(tmp));
  while(n) *p++=tmp[--n];
  return p;
}
static int publish_metrics(int blocking) {
  uint32_t s=osd_status(), s2=osd_read(OSD_STATUS2); char text[80],*p=text;
  uint32_t raw_fps=osd_read(OSD_RAW_FPS)&0xffffu;
  uint32_t resize_fps=osd_read(OSD_RESIZE_FPS)&0xffffu;
  uint32_t display_fps=(s2>>16)&0xffffu;
  uint32_t drop=(s>>11)&0xffu, err=(s>>19)&0xffu;
  p[0]='R';p[1]='A';p[2]='W';p[3]=' ';p=put_dec(p+4,raw_fps);
  *p++=' ';*p++='R';*p++='E';*p++='S';*p++='I';*p++='Z';*p++='E';*p++=' ';p=put_dec(p,resize_fps);
  *p++=' ';*p++='D';*p++='I';*p++='S';*p++='P';*p++=' ';p=put_dec(p,display_fps);
  *p++=' ';*p++='D';*p++='R';*p++='O';*p++='P';*p++=' ';p=put_dec(p,drop);
  *p++=' ';*p++='E';*p++='R';*p++='R';*p++=' ';p=put_dec(p,err);*p=0;
  sapphire_uart_log(text); sapphire_uart_log("\r\n");
  return blocking?osd_write_string(text):osd_submit_string(text);
}

int osd_publish_metrics(void){return publish_metrics(1);}
int osd_submit_metrics(void){return publish_metrics(0);}
