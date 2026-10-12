#include "bsp.h"
#include "plic.h"
#include "style_driver.h"
#include "style_weights.h"
#include "style_selftest.h"
#include "soc_video_driver.h"
#define STYLE_BASE 0xf8100200u
static volatile uint32_t *const regs=(volatile uint32_t *)STYLE_BASE;
volatile uint32_t app_style_irqs,app_style_errors,app_style_last_status,app_style_selftest_errors;
volatile uint32_t app_style_captured,app_style_dropped,app_style_inferred,app_style_cycles;
volatile uint32_t app_style_ddr_delta[12],app_style_read_cycles,app_style_compute_cycles;
static void sync_ddr(void) { __asm__ volatile("fence rw,rw\n.word 0x0000500f" ::: "memory"); }
void style_irq_service(void) {
    uint32_t status=regs[2];app_style_last_status=status;
    // The completion toggle guarantees the CNN snapshot has settled in APB.
    app_style_cycles=regs[7];
    app_style_read_cycles=regs[0xa8/4];app_style_compute_cycles=regs[0xac/4];
    if(status&4u)++app_style_errors;
    regs[2]=status&6u;
    __asm__ volatile("fence iorw,iorw" ::: "memory");
    ++app_style_irqs;
}
void firmware_interrupt_handler(void) {
    uint32_t claim;
    while((claim=plic_claim(BSP_PLIC,BSP_PLIC_CPU_0))!=0u) {
        if(claim==SYSTEM_PLIC_USER_INTERRUPT_A_INTERRUPT)style_irq_service();
        else {++app_style_errors;plic_set_enable(BSP_PLIC,BSP_PLIC_CPU_0,claim,0);}
        plic_release(BSP_PLIC,BSP_PLIC_CPU_0,claim);
    }
}
int style_init_and_selftest(void) {
    if(regs[0]!=0x3154534eu)return -1;
    regs[1]=0;
    uint64_t deadline=clint_getTime(BSP_CLINT)+BSP_CLINT_HZ;
    while((regs[2]&17u)!=16u)if(clint_getTime(BSP_CLINT)>deadline)return -2;
    uint32_t expected_count=((regs[12]&65535u)+6144u)&65535u;
    for(uint32_t row=0;row<256u;++row)for(uint32_t word=0;word<24u;++word) {
        regs[10]=(row<<8)|word;regs[11]=style_coefficients[row*24u+word];
    }
    deadline=clint_getTime(BSP_CLINT)+BSP_CLINT_HZ;
    while(!(regs[2]&16u))if(clint_getTime(BSP_CLINT)>deadline)return -2;
    if(regs[12]!=(expected_count|(expected_count<<16)))return -3;
    plic_set_priority(BSP_PLIC,SYSTEM_PLIC_USER_INTERRUPT_A_INTERRUPT,1);
    plic_set_threshold(BSP_PLIC,BSP_PLIC_CPU_0,0);
    plic_set_enable(BSP_PLIC,BSP_PLIC_CPU_0,SYSTEM_PLIC_USER_INTERRUPT_A_INTERRUPT,1);
    regs[2]=6;regs[3]=1;
    uint32_t external=1u<<11;
    __asm__ volatile("csrs mie,%0\ncsrsi mstatus,8" :: "r"(external) : "memory");
    volatile uint32_t *input=(volatile uint32_t *)0x05000000u;
    volatile uint32_t *output=(volatile uint32_t *)0x05800000u;
    for(uint32_t i=0;i<768u;++i)input[i]=style_test_input[i];
    sync_ddr();regs[4]=0x05000000u;regs[5]=0x05800000u;regs[6]=0x00180020u;
    uint32_t before=app_style_irqs;regs[1]=1;
    deadline=clint_getTime(BSP_CLINT)+BSP_CLINT_HZ;
    while(app_style_irqs==before)if(clint_getTime(BSP_CLINT)>deadline)return -4;
    if(app_style_last_status&4u)return -5;
    sync_ddr();
    for(uint32_t i=0;i<768u;++i)if(output[i]!=style_test_expected[i])++app_style_selftest_errors;
    regs[6]=0x01e00280u;
    return app_style_selftest_errors ? -6:0;
}
void style_stream_enable(void) { regs[1]=16u; }
void style_update_metrics(void) {
    app_style_captured=regs[14];app_style_dropped=regs[15];
    app_style_inferred=regs[16];
}
static char *put_text(char *p,const char *s) {while(*s)*p++=*s++;return p;}
static char *put_decimal(char *p,uint32_t v) {
    char reversed[10];uint32_t n=0;
    do {reversed[n++]=(char)('0'+v%10u);v/=10u;}while(v);
    while(n)*p++=reversed[--n];return p;
}
void style_log_ddr(void) {
    static uint32_t previous[12];uint32_t snapshot[12];
    regs[0x54/4]=1;__asm__ volatile("fence iorw,iorw" ::: "memory");
    for(uint32_t i=0;i<12;++i)snapshot[i]=regs[0x58/4+i];
    regs[0x54/4]=0;__asm__ volatile("fence iorw,iorw" ::: "memory");
    for(uint32_t i=0;i<12;++i){app_style_ddr_delta[i]=snapshot[i]-previous[i];previous[i]=snapshot[i];}
    static const char *const labels[9]={" AR "," DOWN "," RGAP "," RBP "," DBP "," AW "," W "," B "," IDLE "};
    // Also fit ten-digit fields after an unusually long debugger pause or
    // a counter reset between snapshots; these intervals are not valid rates.
    char line[224],*p=put_text(line,"DDR100M T ");p=put_decimal(p,app_style_ddr_delta[0]);
    // Percentages overlap and use the same coherent 100 MHz interval.
    for(uint32_t i=1;i<=9;++i){
        p=put_text(p,labels[i-1]);
        p=put_decimal(p,app_style_ddr_delta[0] ? (uint64_t)app_style_ddr_delta[i]*100u/app_style_ddr_delta[0]:0);
    }
    p=put_text(p," RB ");p=put_decimal(p,app_style_ddr_delta[10]);
    p=put_text(p," DRB ");p=put_decimal(p,app_style_ddr_delta[11]);
    p=put_text(p," RPMS ");p=put_decimal(p,app_style_read_cycles/148500u);
    p=put_text(p," CPMS ");p=put_decimal(p,app_style_compute_cycles/148500u);*p=0;
    uart_writeStr(BSP_UART_TERMINAL,line);uart_writeStr(BSP_UART_TERMINAL,"\r\n");
}
int style_submit_metrics(uint64_t now) {
    static uint64_t previous_time;static uint32_t previous_cap,previous_nn;
    style_update_metrics();uint64_t ticks=now-previous_time;
    uint32_t cap_fps=ticks ? (uint64_t)(app_style_captured-previous_cap)*BSP_CLINT_HZ/ticks:0;
    uint32_t nn_fps=ticks ? (uint64_t)(app_style_inferred-previous_nn)*BSP_CLINT_HZ/ticks:0;
    previous_time=now;previous_cap=app_style_captured;previous_nn=app_style_inferred;
    if(cap_fps>999)cap_fps=999;if(nn_fps>999)nn_fps=999;
    uint32_t display_fps=(*(volatile uint32_t *)0xf8100024u)>>16;
    if(display_fps>999)display_fps=999;
    char line[80],*p=line;
    p=put_text(p,"MONET CAP ");p=put_decimal(p,cap_fps);
    p=put_text(p," NN ");p=put_decimal(p,nn_fps);
    p=put_text(p," DISP ");p=put_decimal(p,display_fps);
    p=put_text(p," DROP ");p=put_decimal(p,app_style_dropped);
    p=put_text(p," MS ");p=put_decimal(p,app_style_cycles/148500u);
    p=put_text(p," ERR ");p=put_decimal(p,app_style_errors+regs[19]+regs[20]);*p=0;
    uart_writeStr(BSP_UART_TERMINAL,line);uart_writeStr(BSP_UART_TERMINAL,"\r\n");
    return osd_submit_string(line);
}
