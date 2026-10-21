#pragma once
#include <stdint.h>
extern volatile uint32_t app_style_irqs,app_style_errors,app_style_last_status,app_style_selftest_errors;
extern volatile uint32_t app_style_captured,app_style_dropped,app_style_inferred,app_style_cycles;
extern volatile uint32_t app_style_ddr_delta[12],app_style_read_cycles,app_style_compute_cycles;
extern volatile uint32_t app_style_prefetch_starts,app_style_prefetch_completions,app_style_overlap_cycles;
int style_init_and_selftest(void);
void style_irq_service(void);
void style_stream_enable(void);
void style_update_metrics(void);
void style_log_ddr(void);
int style_submit_metrics(uint64_t now);
void firmware_interrupt_handler(void);
