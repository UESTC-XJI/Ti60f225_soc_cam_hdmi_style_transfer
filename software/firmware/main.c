#include "bsp.h"
#include "i2c.h"
#include "soc_video_driver.h"

/* Inspect these in the IDE if a trap stops normal UART output. */
volatile uint32_t firmware_trap_cause, firmware_trap_pc, firmware_trap_value;
volatile uint32_t app_ddr_errors, app_osd_errors, app_camera_errors;
volatile uint32_t app_metrics_updates;

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
    bsp_init();
    uart_writeStr(BSP_UART_TERMINAL, "SOC VIDEO boot\r\n");
    if (app_ddr_test()) {
        uart_writeStr(BSP_UART_TERMINAL, "DDR scratch FAIL\r\n");
        for (;;) {}
    }
    uart_writeStr(BSP_UART_TERMINAL, "DDR scratch PASS\r\n");
    camera_bus_init();
    bsp_uDelay(20000);
    int camera_rc = camera_init_cpu();
    if (camera_rc) {
        ++app_camera_errors;
        uart_writeStr(BSP_UART_TERMINAL, "Camera ID/init FAIL; retry every second\r\n");
    } else {
        uart_writeStr(BSP_UART_TERMINAL, "Camera CD6B initialized\r\n");
    }
    if (osd_write_string("HELLO SOC")) {
        ++app_osd_errors;
        uart_writeStr(BSP_UART_TERMINAL, "OSD initial COMMIT timeout\r\n");
    } else {
        uart_writeStr(BSP_UART_TERMINAL, "HELLO SOC\r\n");
    }
    uint64_t last_update = clint_getTime(BSP_CLINT);
    for (;;) {
        uint64_t now = clint_getTime(BSP_CLINT);
        if (now - last_update < BSP_CLINT_HZ) continue;
        if (camera_rc) {
            camera_rc = camera_recover();
            if (camera_rc) ++app_camera_errors;
            else uart_writeStr(BSP_UART_TERMINAL, "Camera recovered\r\n");
        }
        if (app_ddr_test())
            uart_writeStr(BSP_UART_TERMINAL, "DDR concurrent scratch FAIL\r\n");
        if (osd_publish_metrics()) {
            ++app_osd_errors;
            uart_writeStr(BSP_UART_TERMINAL, "OSD metrics COMMIT timeout\r\n");
        }
        ++app_metrics_updates;
        last_update = clint_getTime(BSP_CLINT);
    }
}
