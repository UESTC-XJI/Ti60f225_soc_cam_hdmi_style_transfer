#include "bsp.h"
#include "i2c.h"
#include "soc_video_driver.h"
#include "camera_3a.h"
#include "style_driver.h"

/* Inspect these in the IDE if a trap stops normal UART output. */
volatile uint32_t firmware_trap_cause, firmware_trap_pc, firmware_trap_value;
volatile uint32_t app_ddr_errors, app_osd_errors, app_camera_errors;
volatile uint32_t app_metrics_updates;
volatile uint32_t app_hist_enable,app_hist_updates,app_hist_errors;
video_hist_t app_hist;

#define DDR_TEST_BASE 0x01000000u
#define DDR_TEST_WORDS (64u * 1024u / 4u)

static void camera_bus_init(void) {
    I2c_Config cfg;
    cfg.samplingClockDivider = 3;
    cfg.timeout = SYSTEM_CLINT_HZ / 10;
    cfg.tsuDat = SYSTEM_CLINT_HZ / 100000u / 3;
    cfg.tLow = SYSTEM_CLINT_HZ / 100000u / 2;
    cfg.tHigh = SYSTEM_CLINT_HZ / 100000u / 2;
    cfg.tBuf = SYSTEM_CLINT_HZ / 100000u;
    i2c_applyConfig(SYSTEM_I2C_0_IO_CTRL, &cfg);
}

/* Larger than the 4 KiB D-cache; invalidate before readback. */
int app_ddr_test(void) {
    volatile uint32_t *mem = (volatile uint32_t *)DDR_TEST_BASE;
    uint32_t errors = 0;
    for (uint32_t pass = 0; pass < 2; ++pass) {
        uint32_t seed = pass ? 0x5aa55aa5u : 0xa55aa55au;
        for (uint32_t i = 0; i < DDR_TEST_WORDS; ++i) mem[i] = seed ^ (i * 4u);
        __asm__ volatile ("fence rw,rw\n.word 0x0000500f" ::: "memory");
        for (uint32_t i = 0; i < DDR_TEST_WORDS; ++i)
            if (mem[i] != (seed ^ (i * 4u))) ++errors;
    }
    app_ddr_errors += errors;
    return errors ? -1 : 0;
}

/*==========================================================================
 * 结果帧统计（2026-10-29）—— 为 DC 标定提供**不经 JTAG**的通道均值
 *
 * 为什么需要：OpenOCD 的 mpsse_flush 在大块 dump 上会卡死（一天内十几次），
 *   DC 标定因此完全跑不动。CPU 本来就能读 DDR（style_program_bank 已这么做），
 *   所以让它自己算完、用 UART 打印 —— 彻底绕开 JTAG dump。
 *
 * 口径（与板侧分析脚本一致）：
 *   结果帧 0x05800000，320x240，每像素 {B,G,R,X}（byte0=R），X 必须为 0。
 *   **结果帧是偏移二进制** ⇒ 必须 ^0x80 才是图像（源帧不取反，见 style_display.v:132）。
 *   输出 q = 通道均值 - 128；σ 同域；近灰 = max(R,G,B)-min(R,G,B) < 8 的像素占比。
 *========================================================================*/
#define RESULT_FRAME_BASE 0x05800000u
#define RESULT_W 320u
#define RESULT_H 240u
static char *put_text2(char *p,const char *s){while(*s)*p++=*s++;return p;}
static char *put_dec2(char *p,uint32_t v){char d[10];unsigned n=0;
    do{d[n++]=(char)('0'+v%10);v/=10;}while(v);while(n)*p++=d[--n];return p;}

/* 2026-10-29 修正：**读之前必须停流**。
 *   第一次实现直接读 307 KB，结果 VIDEO 报 FAULT 1、CAP 0 —— CPU 连续读 DDR
 *   与视频/网络管线争抢，把采集打崩了。
 *   照搬 style_switch_bank 的成熟门控：清 stream_enable → 等 pending 退 0 →
 *   读 → 恢复。停流期间帧是静止的，正好适合标定。
 *   另外按 **每 4 个像素取 1 个** 降采样（19,200 个样本，统计上足够），
 *   把 DDR 读量降到 1/4。 */
void style_frame_stats(void) {
    static volatile uint32_t *const fr=(volatile uint32_t *)RESULT_FRAME_BASE;
    static volatile uint32_t *const sregs=(volatile uint32_t *)0xf8100200u;
    uint64_t t0=clint_getTime(BSP_CLINT);
    sregs[1]=0u;                                   /* ① 掐断下一帧任务 */
    uint64_t deadline=t0+BSP_CLINT_HZ/20u;         /* ② 等当前帧跑完（50 ms 上限） */
    while(sregs[2]&1u) {
        if(clint_getTime(BSP_CLINT)>deadline) {
            sregs[1]=16u;
            uart_writeStr(BSP_UART_TERMINAL,"FRAME stats: engine busy timeout\r\n");
            return;
        }
    }
    uint32_t n=RESULT_W*RESULT_H;
    uint32_t s0=0,s1=0,s2=0,q0=0,q1=0,q2=0,ng=0,clip=0,cnt=0;
    /* D-cache 4 KiB，帧 300 KiB ⇒ 读之前必须整片失效，否则读到旧行 */
    __asm__ volatile ("fence rw,rw\n.word 0x0000500f" ::: "memory");
    for(uint32_t i=0;i<n;i+=4u){
        uint32_t w=fr[i];
        uint32_t b= w        &0xFFu;   /* byte0 = R */
        uint32_t g=(w>> 8)   &0xFFu;
        uint32_t r=(w>>16)   &0xFFu;
        uint32_t x=(w>>24)   &0xFFu;
        if(x) continue;
        r^=0x80u; g^=0x80u; b^=0x80u;   /* 偏移二进制 -> 图像 */
        uint32_t mx=r>g?(r>b?r:b):(g>b?g:b);
        uint32_t mn=r<g?(r<b?r:b):(g<b?g:b);
        if(mx-mn<8u) ++ng;
        if(r>=254u||g>=254u||b>=254u) ++clip;
        s0+=r; s1+=g; s2+=b; q0+=r*r; q1+=g*g; q2+=b*b; ++cnt;
    }
    sregs[1]=16u;                                  /* ③ 恢复流水线 */
    if(!cnt){uart_writeStr(BSP_UART_TERMINAL,"FRAME stats: no pixels\r\n");return;}
    /* 返回 q 均值（定标 100 倍，Q8 便于判读）与 sigma（100 倍） */
    int32_t m0=(int32_t)(s0/cnt)-128, m1=(int32_t)(s1/cnt)-128, m2=(int32_t)(s2/cnt)-128;
    uint32_t v0=(uint32_t)(q0/cnt)-(uint32_t)((s0/cnt)*(s0/cnt));
    uint32_t v1=(uint32_t)(q1/cnt)-(uint32_t)((s1/cnt)*(s1/cnt));
    uint32_t v2=(uint32_t)(q2/cnt)-(uint32_t)((s2/cnt)*(s2/cnt));
    /* 整数 sqrt */
    uint32_t r0=0,r1=0,r2=0;
    for(uint32_t k=1u<<14;k;k>>=1){if((r0+k)*(r0+k)<=v0)r0+=k;if((r1+k)*(r1+k)<=v1)r1+=k;if((r2+k)*(r2+k)<=v2)r2+=k;}
    char t[160],*p=t;
    p=put_text2(p,"FRAME q ");p=put_dec2(p,(uint32_t)(m0));
    p=put_text2(p," ");p=put_dec2(p,(uint32_t)(m1));
    p=put_text2(p," ");p=put_dec2(p,(uint32_t)(m2));
    p=put_text2(p," sig ");p=put_dec2(p,r0);
    p=put_text2(p," ");p=put_dec2(p,r1);
    p=put_text2(p," ");p=put_dec2(p,r2);
    p=put_text2(p," neargray ");p=put_dec2(p,(uint32_t)(ng*1000u/cnt));
    p=put_text2(p," clip ");p=put_dec2(p,(uint32_t)(clip*1000u/cnt));
    *p++='\r';*p++='\n';*p=0;
    uart_writeStr(BSP_UART_TERMINAL,t);
}

/* C1：串口命令口。'1'..'N' = 切到第 N 套风格，'s'/'?' = 打印清单。
 * uart_read() 本身会阻塞等数据，所以先查 RX FIFO 占用再读。 */
static void style_uart_service(void) {
    while(uart_readOccupancy(BSP_UART_TERMINAL)) {
        char c=(char)uart_read(BSP_UART_TERMINAL);
        if(c>='1'&&c<=(char)('0'+style_bank_count()))style_switch_bank((unsigned)(c-'1'));
        else if(c=='s'||c=='S'||c=='?')style_list_banks();
        else if(c=='q'||c=='Q')style_frame_stats();   /* 结果帧通道均值（DC 标定用，绕开 JTAG） */
    }
}
int main(void) {
    osd_set_video_ready(0);  /* Also return to bars after a debugger reload. */
    bsp_init();
    uart_writeStr(BSP_UART_TERMINAL, "SOC VIDEO boot\r\n");
    if (app_ddr_test()) {
        uart_writeStr(BSP_UART_TERMINAL, "DDR scratch FAIL\r\n");
        for (;;) {}
    }
    uart_writeStr(BSP_UART_TERMINAL, "DDR scratch PASS\r\n");
    int style_rc=style_init_and_selftest();
    if(style_rc) {
        ++app_style_errors;
        uart_writeStr(BSP_UART_TERMINAL,"STYLE weights/IRQ/RGB self-test FAIL; inspect status\r\n");
        for(;;) {}
    }
    uart_writeStr(BSP_UART_TERMINAL,"STYLE INT8 RGB self-test PASS; MONET VGA\r\n");
    style_stream_enable();
    /* C1：清掉上电时 UART RX 里的残留字节，再公布可切换的风格清单 */
    while(uart_readOccupancy(BSP_UART_TERMINAL))(void)uart_read(BSP_UART_TERMINAL);
    uart_writeStr(BSP_UART_TERMINAL,"STYLE SW: keys 1..N switch live, 's' lists\r\n");
    style_list_banks();
    camera_bus_init();
    bsp_uDelay(20000);
    int camera_rc = camera_init_cpu();
    if (camera_rc) {
        ++app_camera_errors;
        uart_writeStr(BSP_UART_TERMINAL, "Camera ID/init FAIL; retry every second\r\n");
    } else {
        uart_writeStr(BSP_UART_TERMINAL, "Camera CD6B initialized\r\n");
    }
    int osd_rc = osd_write_string("MONET VGA");
    if (osd_rc) {
        ++app_osd_errors;
        uart_writeStr(BSP_UART_TERMINAL, "OSD initial COMMIT timeout\r\n");
    } else {
        uart_writeStr(BSP_UART_TERMINAL, "MONET VGA\r\n");
    }
    if (camera_rc == 0 && osd_rc == 0) osd_set_video_ready(1);
    uint64_t last_update = clint_getTime(BSP_CLINT);
    if(!camera_rc) {
        int rc=camera_3a_init(&app_3a,last_update);
        uart_writeStr(BSP_UART_TERMINAL,rc?"Software AE/AWB unavailable (CAPS/VTS/I2C); inspect app_3a\r\n":
                      "Software AE/AWB enabled; RAW8 stats, fixed VTS, manual lift\r\n");
    }
    uint64_t last_service=last_update,osd_started=last_update;
    int osd_pending=0;
    for (;;) {
        uint64_t now = clint_getTime(BSP_CLINT);
        if(now-last_service>=BSP_CLINT_HZ/1000u) {
            style_uart_service();
            if(!camera_rc)camera_3a_service(&app_3a,now);
            if(app_hist_enable) {
                int rc=video_hist_poll(&app_hist);
                if(rc>0)++app_hist_updates;else if(rc<0)++app_hist_errors;
            }
            last_service=now;
        }
        if(osd_pending) {
            if(osd_poll()) {osd_pending=0;osd_rc=0;if(!camera_rc)osd_set_video_ready(1);}
            else if(now-osd_started>=BSP_CLINT_HZ/4u) {
                osd_pending=0;osd_rc=-1;++app_osd_errors;
                uart_writeStr(BSP_UART_TERMINAL,"OSD metrics COMMIT timeout\r\n");
            }
        }
        if (now - last_update < BSP_CLINT_HZ) continue;
        if (camera_rc) {
            camera_rc = camera_recover();
            if (camera_rc) ++app_camera_errors;
            else {
                uart_writeStr(BSP_UART_TERMINAL, "Camera recovered\r\n");
                camera_3a_init(&app_3a,clint_getTime(BSP_CLINT));
            }
        }
        // Full DDR stress runs at boot; do not pause 3A for a 64 KiB test each second.
        if(!osd_pending) {
            osd_rc=style_submit_metrics(now);
            if(!osd_rc){osd_pending=1;osd_started=clint_getTime(BSP_CLINT);}
            else if(!( *(volatile uint32_t *)(0xf8100020u)&4u))++app_osd_errors;
        }
        if(app_3a.enabled||app_3a.status)camera_3a_log(&app_3a);
        style_update_metrics();
        style_log_ddr();
        ++app_metrics_updates;
        last_update = clint_getTime(BSP_CLINT);
    }
}
