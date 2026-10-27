#include "bsp.h"
#include "plic.h"
#include "style_driver.h"
#include "rowpipe_weights.h"
#include "style_selftest.h"
#include "soc_video_driver.h"
#define STYLE_BASE 0xf8100200u
static volatile uint32_t *const regs=(volatile uint32_t *)STYLE_BASE;
volatile uint32_t app_style_irqs,app_style_errors,app_style_last_status,app_style_selftest_errors;
volatile uint32_t app_style_captured,app_style_dropped,app_style_inferred,app_style_cycles;
volatile uint32_t app_style_ddr_delta[12],app_style_read_cycles,app_style_compute_cycles;
volatile uint32_t app_style_prefetch_starts,app_style_prefetch_completions,app_style_overlap_cycles;
static void sync_ddr(void) { __asm__ volatile("fence rw,rw\n.word 0x0000500f" ::: "memory"); }
void style_irq_service(void) {
    uint32_t status=regs[2];app_style_last_status=status;
    // The completion toggle guarantees the CNN snapshot has settled in APB.
    app_style_cycles=regs[7];
    app_style_read_cycles=regs[0xa8/4];app_style_compute_cycles=regs[0xac/4];
    app_style_prefetch_starts=regs[0xb0/4];app_style_prefetch_completions=regs[0xb4/4];app_style_overlap_cycles=regs[0xb8/4];
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
    // 2026-10-19 rowpipe：权重走 DDR blob（WEIGHT_ADDRESS=0x06F0_0000，22,512 B），
    // 上电写一次；布局 = INTERFACE.md sec 8 的 1,407 个 16B beat。
    volatile uint32_t *weights=(volatile uint32_t *)0x06F00000u;
    for(uint32_t i=0;i<ROWPIPE_WEIGHT_WORDS;++i)weights[i]=rowpipe_weights[i];
    sync_ddr();
    uint32_t xor_check=0;
    for(uint32_t i=0;i<ROWPIPE_WEIGHT_WORDS;++i)xor_check^=weights[i];
    if(xor_check!=ROWPIPE_WEIGHT_XOR)return -3;
    plic_set_priority(BSP_PLIC,SYSTEM_PLIC_USER_INTERRUPT_A_INTERRUPT,1);
    plic_set_threshold(BSP_PLIC,BSP_PLIC_CPU_0,0);
    plic_set_enable(BSP_PLIC,BSP_PLIC_CPU_0,SYSTEM_PLIC_USER_INTERRUPT_A_INTERRUPT,1);
    regs[2]=6;regs[3]=1;
    uint32_t external=1u<<11;
    __asm__ volatile("csrs mie,%0\ncsrsi mstatus,8" :: "r"(external) : "memory");
    regs[4]=0x05000000u;regs[5]=0x05800000u;regs[6]=0x01e00280u;
    // rowpipe 的输出与 Monet 的 32x24 金样不同；功能确认交给首帧运行 +
    // UART 的 NN/ERR 指标，这里只保证权重已就绪。
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
    static uint32_t previous_underflow,previous_drop;
    regs[0x54/4]=1;__asm__ volatile("fence iorw,iorw" ::: "memory");
    for(uint32_t i=0;i<12;++i)snapshot[i]=regs[0x58/4+i];
    regs[0x54/4]=0;__asm__ volatile("fence iorw,iorw" ::: "memory");
    for(uint32_t i=0;i<12;++i){app_style_ddr_delta[i]=snapshot[i]-previous[i];previous[i]=snapshot[i];}
    // 2026-10-27：style_ddr_profiler 只实现 5 项（PnR 面积约束，见 RTL 文件头注）：
    //   索引 0=总拍数(T) 1=CNN AR 反压 2=显示 AR 反压 3=读气泡(burst 在飞无 beat) 8=等B
    // 其余索引恒 0，不再打印。
    // 提示：位序反着数会得到完全错误的分工 —— 0=总拍数, 8=等B，不是反过来。
    //
    // 2026-10-27：下面 5 项（RPMS/CPMS/PF/PFC/WW）来自 style_network_rowpipe 的
    // stat_* 快照（APB 0xa8..0xb8）。此前它们硬接 0，现已按修正口径接回：
    //   RPMS = read_cycles/148500  —— 读等待毫秒（AR 未接受 或 burst 在飞无 beat）
    //   CPMS = compute_cycles/148500 —— 其余（drv_cycles − read_cycles）
    //   PF/PFC = 发出的/完成的读 burst 数（PF−PFC 应 ≤ 2，否则说明有 burst 卡住）
    //   WW = 等写响应毫秒（原 OVLP 槽位改用，与上面 profiler 的 B 应大致吻合）
    char line[320],*p=put_text(line,"DDR100M T ");p=put_decimal(p,app_style_ddr_delta[0]);
    {
        uint32_t tot=app_style_ddr_delta[0];
        p=put_text(p," AR ");  p=put_decimal(p,tot?(uint64_t)app_style_ddr_delta[1]*100u/tot:0);
        p=put_text(p," DAR "); p=put_decimal(p,tot?(uint64_t)app_style_ddr_delta[2]*100u/tot:0);
        p=put_text(p," RGAP ");p=put_decimal(p,tot?(uint64_t)app_style_ddr_delta[3]*100u/tot:0);
        p=put_text(p," B ");   p=put_decimal(p,tot?(uint64_t)app_style_ddr_delta[8]*100u/tot:0);
    }
    p=put_text(p," RPMS ");p=put_decimal(p,app_style_read_cycles/148500u);
    p=put_text(p," CPMS ");p=put_decimal(p,app_style_compute_cycles/148500u);
    p=put_text(p," PF ");  p=put_decimal(p,app_style_prefetch_starts);
    p=put_text(p," PFC "); p=put_decimal(p,app_style_prefetch_completions);
    p=put_text(p," WW ");  p=put_decimal(p,app_style_overlap_cycles/148500u);
    *p=0;
    uart_writeStr(BSP_UART_TERMINAL,line);uart_writeStr(BSP_UART_TERMINAL,"\r\n");
    // Display starvation is independent of style queue drops and AXI errors.
    // Read the existing status counters; no new FPGA storage is required.
    volatile uint32_t *const video_regs=(volatile uint32_t *)0xf8100000u;
    uint32_t underflows=video_regs[0x14c/4],drops=regs[0x3c/4];
    p=put_text(line,"VIDEO UF ");p=put_decimal(p,underflows);
    p=put_text(p," DUF ");p=put_decimal(p,underflows-previous_underflow);
    p=put_text(p," DDROP ");p=put_decimal(p,drops-previous_drop);
    p=put_text(p," FAULT ");p=put_decimal(p,video_regs[0x140/4]);
    p=put_text(p," CSI ");p=put_decimal(p,video_regs[0x15c/4]);
    p=put_text(p," DME ");p=put_decimal(p,regs[0x4c/4]);
    p=put_text(p," IERR ");p=put_decimal(p,regs[0x44/4]);
    p=put_text(p," AXI ");p=put_decimal(p,video_regs[0x148/4]);*p=0;
    previous_underflow=underflows;previous_drop=drops;
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
