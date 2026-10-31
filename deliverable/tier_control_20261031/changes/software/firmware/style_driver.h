#pragma once
#include <stdint.h>
extern volatile uint32_t app_style_irqs,app_style_errors,app_style_last_status,app_style_selftest_errors;
extern volatile uint32_t app_style_captured,app_style_dropped,app_style_inferred,app_style_cycles;
extern volatile uint32_t app_style_ddr_delta[12],app_style_read_cycles,app_style_compute_cycles;
extern volatile uint32_t app_style_prefetch_starts,app_style_prefetch_completions,app_style_overlap_cycles;
/* C1 多风格运行期切换 */
extern volatile uint32_t app_style_switches,app_style_switch_errors;
extern volatile uint32_t app_style_switch_wait_us,app_style_switch_copy_us,app_style_switch_total_us;
int style_init_and_selftest(void);
unsigned style_bank_count(void);
unsigned style_active_bank(void);
unsigned style_tier_count(unsigned index);
unsigned style_active_tier(void);
const char *style_tier_name(unsigned index,unsigned tier);
const char *style_bank_name(unsigned index);
void style_list_banks(void);
int style_switch_bank(unsigned index);
int style_set_tier(unsigned index,unsigned tier);
void style_irq_service(void);
void style_stream_enable(void);
void style_stream_set(int on);
int style_busy(void);
int style_display_slot(void);
void style_update_metrics(void);
void style_log_ddr(void);
int style_submit_metrics(uint64_t now);
void firmware_interrupt_handler(void);
