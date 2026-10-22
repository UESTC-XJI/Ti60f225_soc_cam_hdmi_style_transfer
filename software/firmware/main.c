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
