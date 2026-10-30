#include "bsp.h"
#include "i2c.h"
#include "soc_video_driver.h"
#include "camera_3a.h"
#include "style_driver.h"
#include "qse_ble.h"

/* Inspect these in the IDE if a trap stops the application. */
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

/* ---- 旋钮档位 G1..G4（2026-10-28，沿用 10-26 的板级接法）----------------
 * QSE 旋钮的两位 {SW2,SW1} 从 video APB 0x54 的 bit[3:2] 读进（bit2=SW1，bit3=SW2）：
 *     raw 0b00 -> G3 彩虹        raw 0b01 -> G1 星空
 *     raw 0b10 -> G2 red_sky     raw 0b11 -> G4 保持
 * G4 保持当前 active；G3 明确选择彩虹 bank4。
 * 20 ms 消抖（1 kHz 轮询 = 20 拍）；切换走 style_switch_bank()（等引擎空闲再拷权重，
 * 实测 32 ms，不丢帧）。串口日志已移除：UART0 现在专供 BLE。 */
static uint32_t knob_raw=0xFFFFFFFFu, knob_stable;
static uint64_t knob_since;

static void style_knob_apply(uint32_t raw) {
    unsigned target;
    switch (raw) {
    case 0u:  target = 4u; break;                          /* G3 彩虹（bank4 rainbow） */
    case 1u:  target = 0u; break;                          /* G1 星空（bank0 starry_old） */
    case 2u:  target = 3u; break;                          /* G2 red_sky（bank3 red_v3_dc） */
    default:  target = style_active_bank(); break;         /* G4 保持 */
    }
    if (target != style_active_bank() && target < style_bank_count())
        (void)style_switch_bank(target);
    qse_ble_note_knob(raw);
}

/* 上电就按旋钮的实际档位上电（旋钮在 G2 就开机即 red_sky），
 * 而不是"等第一次拨动才生效"。G4 保持当前 active，G3 选择彩虹 bank4。 */
static void style_knob_reset(uint64_t now) {
    knob_raw = (*(volatile uint32_t *)0xF8100054u >> 2) & 3u;
    knob_stable = knob_raw; knob_since = now;
    style_knob_apply(knob_stable);
}

static void style_knob_service(uint64_t now) {
    uint32_t raw = (*(volatile uint32_t *)0xF8100054u >> 2) & 3u;
    if (raw != knob_raw) { knob_raw = raw; knob_since = now; return; }
    if (raw == knob_stable) return;
    if (now - knob_since < BSP_CLINT_HZ / 50u) return;     /* 20 ms */
    knob_stable = raw;
    style_knob_apply(knob_stable);
}

int main(void) {
    osd_set_video_ready(0);  /* Also return to bars after a debugger reload. */
    bsp_init();
    if (app_ddr_test()) {
        for (;;) {}
    }
    int style_rc=style_init_and_selftest();
    if(style_rc) {
        ++app_style_errors;
        for(;;) {}
    }
    style_stream_enable();

    /* UART0 switches from the 115200 debug console to the 128000 BLE link here.
     * From this point every byte on the port belongs to the BLE protocol. */
    uint64_t boot_now = clint_getTime(BSP_CLINT);
    qse_ble_init(boot_now);
    style_knob_reset(boot_now);

    camera_bus_init();
    bsp_uDelay(20000);
    int camera_rc = camera_init_cpu();
    if (camera_rc) {
        ++app_camera_errors;
    } else {
        (void)osd_write_string("MONET VGA");
    }
    if (camera_rc == 0) osd_set_video_ready(1);
    uint64_t last_update = clint_getTime(BSP_CLINT);
    if(!camera_rc) {
        (void)camera_3a_init(&app_3a,last_update);
    }
    uint64_t last_service=last_update;
    for (;;) {
        uint64_t now = clint_getTime(BSP_CLINT);
        qse_ble_poll(now);
        if(now-last_service>=BSP_CLINT_HZ/1000u) {
            style_knob_service(now);
            if(!camera_rc)camera_3a_service(&app_3a,now);
            if(app_hist_enable) {
                int rc=video_hist_poll(&app_hist);
                if(rc>0)++app_hist_updates;else if(rc<0)++app_hist_errors;
            }
            last_service=now;
        }
        if (now - last_update < BSP_CLINT_HZ) continue;
        if (camera_rc) {
            camera_rc = camera_recover();
            if (camera_rc) ++app_camera_errors;
            else camera_3a_init(&app_3a,clint_getTime(BSP_CLINT));
        }
        style_update_metrics();
        ++app_metrics_updates;
        last_update = clint_getTime(BSP_CLINT);
    }
}
