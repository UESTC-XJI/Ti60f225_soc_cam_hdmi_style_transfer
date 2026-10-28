#include "bsp.h"
#include "plic.h"
#include "style_driver.h"
#include "rowpipe_weights.h"
#include "style_banks.h"
#include "style_selftest.h"
#include "soc_video_driver.h"
#define STYLE_BASE 0xf8100200u
static volatile uint32_t *const regs=(volatile uint32_t *)STYLE_BASE;

/* ---- C1：运行期切换风格 ----------------------------------------------------
 * 引擎每帧都从 DDR 0x06F00000 重读权重（rowpipe_engine 的 wbase_of/流式读），
 * 所以"换风格"= 在**引擎空闲**时改写这段 14,448 B。关键约束：
 *   style_frame_store.sv:36  pop_ready = stream_enable && nn_ready && !infer_active && ready_found
 * 满载时下一帧任务在 job_done 后 1 个时钟就启动，pending 位只出现 1 拍，
 * CPU 根本poll不到 ⇒ 必须先把 regs[1].bit4(stream_enable) 清 0 掐断 pop_ready，
 * 等 pending 稳定为 0，再写权重，最后恢复。 */
#define STYLE_DDR_WEIGHTS ((volatile uint32_t *)0x06F00000u)
#define STYLE_BANK_COUNT 5u
#define STYLE_STREAM_ON 16u

typedef struct { const char *name; const unsigned int *words; uint32_t xor_expected; } style_bank_t;
/* bank 0 = 构建期烧进来的 rowpipe_weights.h（当前 redsky v5 / 呐喊, 0xcbc67865） */
/* 2026-10-28 修正（硬件侧）：原表有两处问题 ——
 *   ① bank0 标签写的是 "redsky_v5"，但它的数据是 `rowpipe_weights`，
 *      而 `ROWPIPE_WEIGHT_XOR = 0xb995616f` **就是 starry_old**（与 bank4 同一个 XOR）。
 *      => 标签是错的，演示时 `s` 列清单会显示一个不存在的风格名。
 *   ② bank4 与 bank0 的 XOR 相同 => 同一份权重存了两遍，白占 14,448 B flash。
 *      而 .bin 已经因为权库从 28,360 涨到 87,904 B，不该再浪费。
 * 修法：bank0 改名为 starry_old，删掉重复的 bank4 => 4 套互不相同的风格。
 * 开机仍走 `style_program_bank(0)`，**默认风格不变**（还是 starry_old）。 */
static const style_bank_t style_banks[STYLE_BANK_COUNT]={
    {"starry_old",rowpipe_weights,        ROWPIPE_WEIGHT_XOR},
    {"starry_v7", style_bank_starry_v7,   STYLE_BANK_STARRY_V7_XOR},
    {"starry_v8", style_bank_starry_v8,   STYLE_BANK_STARRY_V8_XOR},
    {"red_v3_dc", style_bank_red_v3_dc,   STYLE_BANK_RED_V3_DC_XOR},
    {"rainbow",   style_bank_rainbow,     STYLE_BANK_RAINBOW_XOR},
};
static unsigned style_active_bank_index;
static volatile uint64_t style_switch_t0;
static volatile uint32_t style_switch_armed;
static char *put_text(char *p,const char *s);
static char *put_decimal(char *p,uint32_t v);
volatile uint32_t app_style_irqs,app_style_errors,app_style_last_status,app_style_selftest_errors;
volatile uint32_t app_style_switches,app_style_switch_errors,app_style_switch_wait_us,app_style_switch_copy_us,app_style_switch_total_us;
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
    /* C1：切换后第一个"用新权重"的任务完成时，记下命令→出图的实测延迟。
     * 这里在中断里算，因为它就是"新风格已算完、等显示读"的那一刻（显示再加 ≤1 帧）。 */
    if(style_switch_armed) {
        style_switch_armed=0;
        app_style_switch_total_us=(uint32_t)((clint_getTime(BSP_CLINT)-style_switch_t0)*1000000ull/BSP_CLINT_HZ);
    }
}
void firmware_interrupt_handler(void) {
    uint32_t claim;
    while((claim=plic_claim(BSP_PLIC,BSP_PLIC_CPU_0))!=0u) {
        if(claim==SYSTEM_PLIC_USER_INTERRUPT_A_INTERRUPT)style_irq_service();
        else {++app_style_errors;plic_set_enable(BSP_PLIC,BSP_PLIC_CPU_0,claim,0);}
        plic_release(BSP_PLIC,BSP_PLIC_CPU_0,claim);
    }
}
/* 把一套 blob 写进引擎读的那个 DDR 窗口并做 XOR 自检。返回 0 = 写入并校验通过。 */
static int style_program_bank(unsigned index) {
    const style_bank_t *bank=&style_banks[index];
    volatile uint32_t *dst=STYLE_DDR_WEIGHTS;
    for(uint32_t i=0;i<ROWPIPE_WEIGHT_WORDS;++i)dst[i]=bank->words[i];
    sync_ddr();
    uint32_t xor_check=0;
    for(uint32_t i=0;i<ROWPIPE_WEIGHT_WORDS;++i)xor_check^=dst[i];
    return xor_check==bank->xor_expected?0:-1;
}
static uint32_t style_us(uint64_t ticks) {
    return (uint32_t)(ticks*1000000ull/BSP_CLINT_HZ);
}
unsigned style_bank_count(void) { return STYLE_BANK_COUNT; }
unsigned style_active_bank(void) { return style_active_bank_index; }
const char *style_bank_name(unsigned index) {
    return index<STYLE_BANK_COUNT?style_banks[index].name:"?";
}
void style_list_banks(void) {
    char line[96],*p=line;
    p=put_text(p,"STYLE BANKS");
    for(unsigned i=0;i<STYLE_BANK_COUNT;++i) {
        p=put_text(p," ");
        p=put_decimal(p,i+1u);
        p=put_text(p,":");
        p=put_text(p,style_banks[i].name);
        if(i==style_active_bank_index)p=put_text(p,"*");
    }
    *p++='\r';*p++='\n';*p=0;
    uart_writeStr(BSP_UART_TERMINAL,line);
}
/* 运行期切换：UART 收到 '1'..'5' 调用。会阻塞到当前帧退休（≤50 ms 上限）。 */
int style_switch_bank(unsigned index) {
    if(index>=STYLE_BANK_COUNT)return -1;
    if(index==style_active_bank_index) {              /* 已经是这套，不做事 */
        char line[64],*p=line;
        p=put_text(p,"STYLE SW ");p=put_decimal(p,index+1u);
        p=put_text(p," already active\r\n");*p=0;
        uart_writeStr(BSP_UART_TERMINAL,line);
        return 1;
    }
    uint64_t t0=clint_getTime(BSP_CLINT);
    /* ① 先掐断"下一帧任务"：pop_ready 需要 stream_enable（style_frame_store.sv:36） */
    regs[1]=0u;
    /* ② 等当前帧跑完。掐断后 pending 会稳定停在 0（不再被拉起）。 */
    uint64_t deadline=t0+BSP_CLINT_HZ/20u;           /* 50 ms 上限（一帧 ≈39 ms） */
    while(regs[2]&1u) {
        if(clint_getTime(BSP_CLINT)>deadline) {
            regs[1]=STYLE_STREAM_ON;
            ++app_style_switch_errors;
            uart_writeStr(BSP_UART_TERMINAL,"STYLE SW FAIL: engine busy timeout\r\n");
            return -2;
        }
    }
    uint64_t t1=clint_getTime(BSP_CLINT);
    /* ③ 写权重 + XOR 自检（失败则回滚到上一套，绝不把坏 blob 留在 DDR 里） */
    if(style_program_bank(index)) {
        style_program_bank(style_active_bank_index);
        regs[1]=STYLE_STREAM_ON;
        ++app_style_switch_errors;
        uart_writeStr(BSP_UART_TERMINAL,"STYLE SW FAIL: verify, rolled back\r\n");
        return -3;
    }
    uint64_t t2=clint_getTime(BSP_CLINT);
    /* ④ 放行采集与下一帧任务：排队的帧会立刻用新权重起跑 */
    regs[1]=STYLE_STREAM_ON;
    style_active_bank_index=index;
    style_switch_t0=t0;style_switch_armed=1;
    app_style_switch_wait_us=style_us(t1-t0);
    app_style_switch_copy_us=style_us(t2-t1);
    ++app_style_switches;
    {
        char line[96],*p=line;
        p=put_text(p,"STYLE SW ");p=put_decimal(p,index+1u);
        p=put_text(p," ");p=put_text(p,style_banks[index].name);
        p=put_text(p," ok wait ");p=put_decimal(p,app_style_switch_wait_us);
        p=put_text(p,"us copy ");p=put_decimal(p,app_style_switch_copy_us);
        p=put_text(p,"us");*p++='\r';*p++='\n';*p=0;
        uart_writeStr(BSP_UART_TERMINAL,line);
    }
    return 0;
}
int style_init_and_selftest(void) {
    if(regs[0]!=0x3154534eu)return -1;
    regs[1]=0;
    uint64_t deadline=clint_getTime(BSP_CLINT)+BSP_CLINT_HZ;
    while((regs[2]&17u)!=16u)if(clint_getTime(BSP_CLINT)>deadline)return -2;
    // 权重走 DDR blob：引擎固定从 0x06F0_0000 读（WEIGHT_ADDRESS 是 RTL 编译期常量），
    // 布局 = 903 个 16B beat = 14,448 B = 3,612 word（rowpipe_engine wbase_of 之和）。
    // bank 0 是构建期烧进来的那套；运行期切换见 style_switch_bank()。
    if(style_program_bank(0u))return -3;
    style_active_bank_index=0u;
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
    p=put_text(p," AXI ");p=put_decimal(p,video_regs[0x148/4]);
    /* C1：切换遥测 —— SW = 成功次数, SWT = 命令→新风格算完的实测延迟(ms) */
    p=put_text(p," SW ");p=put_decimal(p,app_style_switches);
    p=put_text(p," SWT ");p=put_decimal(p,app_style_switch_total_us/1000u);
    p=put_text(p," SWE ");p=put_decimal(p,app_style_switch_errors);*p=0;
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
