#include "bsp.h"
#include "style_driver.h"
#include "qse_ble.h"
#include "qse_imgtx.h"

/* UART0 carries the BLE protocol on this build. The debug console is gone, so
 * every writer on this port must go through qse_ble_send_line()/tx_put(). */
#define BLE_UART SYSTEM_UART_0_IO_CTRL
#define RX_GAP_TICKS ((uint64_t)BSP_CLINT_HZ / 20u)   /* 50 ms without a byte ends a line */
#define RX_LINE_MAX 64u
#define TX_QUEUE 1024u                                /* power of two */
#define TX_BURST 20u                                  /* one BLE notification */
#define HZ ((uint64_t)BSP_CLINT_HZ)

volatile uint32_t qse_ble_tx_msgs, qse_ble_rx_bytes, qse_ble_tx_drops;
volatile uint32_t qse_ble_rate = QSE_BLE_RATE;
volatile uint32_t qse_ble_knob;

static uint8_t tx_queue[TX_QUEUE];
static uint32_t tx_head, tx_tail;  /* free-running; head - tail = queued bytes */
static uint32_t tx_tokens;
static uint64_t tx_last;

static char rx_line[RX_LINE_MAX];
static uint32_t rx_len;
static uint64_t rx_last;

static uint32_t knob_pos;

uint32_t qse_ble_tx_space(void) { return TX_QUEUE - (tx_head - tx_tail); }
uint32_t qse_ble_tx_pending(void) { return tx_head - tx_tail; }

static char *put_dec(char *p, uint32_t v) {
    char r[10]; uint32_t n = 0;
    do { r[n++] = (char)('0' + v % 10u); v /= 10u; } while (v);
    while (n) *p++ = r[--n];
    return p;
}

static void send_pair(const char *tag, uint32_t v) {
    char m[32], *p = m;
    while (*tag && p < m + 24) *p++ = *tag++;
    *p++ = ',';
    p = put_dec(p, v);
    *p = 0;
    qse_ble_send_line(m);
}

int qse_ble_tx_put(const uint8_t *data, uint32_t len) {
    if (len > qse_ble_tx_space()) return -1;
    for (uint32_t i = 0; i < len; ++i) tx_queue[(tx_head + i) & (TX_QUEUE - 1u)] = data[i];
    tx_head += len;
    return 0;
}

void qse_ble_send_line(const char *s) {
    uint8_t buf[RX_LINE_MAX + 2];
    uint32_t n = 0;
    while (s[n] && n < RX_LINE_MAX) { buf[n] = (uint8_t)s[n]; ++n; }
    buf[n++] = '\r';
    buf[n++] = '\n';
    if (qse_ble_tx_put(buf, n)) ++qse_ble_tx_drops;
    else ++qse_ble_tx_msgs;
}

/* Token bucket: the BLE module has no flow control, so the UART never runs
 * ahead of what the link can carry (qse_ble_rate bytes/s, burst TX_BURST). */
static void tx_drain(uint64_t now) {
    uint64_t dt = now - tx_last;
    if (dt > HZ) { dt = HZ; tx_last = now - HZ; }
    uint32_t earned = (uint32_t)(dt * qse_ble_rate / HZ);
    if (earned) {
        tx_last += (uint64_t)earned * HZ / qse_ble_rate;
        tx_tokens = tx_tokens + earned > TX_BURST ? TX_BURST : tx_tokens + earned;
    }
    uint32_t room = uart_writeAvailability(BLE_UART);
    while (room && tx_tokens && tx_tail != tx_head) {
        write_u32(tx_queue[tx_tail & (TX_QUEUE - 1u)], BLE_UART + UART_DATA);
        ++tx_tail; --room; --tx_tokens;
    }
}

static int parse_uint(const char *s, uint32_t *v) {
    uint32_t n = 0, digits = 0;
    while (*s >= '0' && *s <= '9' && digits < 6) { n = n * 10u + (uint32_t)(*s++ - '0'); ++digits; }
    if (!digits || *s) return -1;
    *v = n;
    return 0;
}

/* Same raw-position table as main.c: 0b00 -> G3 rainbow (bank 4),
 * 0b01 -> G1 starry (bank 0), 0b10 -> G2 red_sky (bank 3), 0b11 -> hold. */
static int bank_for_pos(uint32_t p) {
    switch (p & 3u) {
    case 0: return 4;
    case 1: return 0;
    case 2: return 3;
    default: return -1;
    }
}

static void send_bank(void) {
    char m[64], *p = m;
    *p++ = 'B'; *p++ = 'A'; *p++ = 'N'; *p++ = 'K'; *p++ = ',';
    p = put_dec(p, style_active_bank());
    *p++ = ',';
    const char *n = style_bank_name(style_active_bank());
    while (*n && p < m + 60) *p++ = *n++;
    *p = 0;
    qse_ble_send_line(m);
}

void qse_ble_note_knob(uint32_t pos) {
    knob_pos = pos & 3u;
    qse_ble_knob = knob_pos;
    send_pair("KNOB", knob_pos);
}

static int ui_command(const char *c) {
    uint32_t v;
    if (c[0] == 'K' && c[1] == 'N' && c[2] == 'O' && c[3] == 'B' && c[4] == ',') {
        if (!parse_uint(c + 5, &v) && v <= 3u) {
            knob_pos = v; qse_ble_knob = v;
            int b = bank_for_pos(v);
            if (b >= 0 && (unsigned)b < style_bank_count()) (void)style_switch_bank((unsigned)b);
            send_pair("KNOB", v);
            send_bank();
            return 1;
        }
    } else if (c[0] == 'R' && c[1] == 'A' && c[2] == 'T' && c[3] == 'E') {
        if (!c[4]) { send_pair("RATE", qse_ble_rate); return 1; }
        if (c[4] == ',' && !parse_uint(c + 5, &v)) {
            qse_ble_rate = v < QSE_BLE_RATE_MIN ? QSE_BLE_RATE_MIN : v > QSE_BLE_RATE_MAX ? QSE_BLE_RATE_MAX : v;
            send_pair("RATE", qse_ble_rate);
            return 1;
        }
    } else if (c[0] == 'S' && c[1] == 'T' && c[2] == 'A' && c[3] == 'T' && c[4] == 'E' && !c[5]) {
        send_pair("KNOB", knob_pos);
        send_bank();
        send_pair("RATE", qse_ble_rate);
        return 1;
    }
    return 0;
}

/* A complete received line: commands are executed, anything else is echoed. */
static void rx_dispatch(uint64_t now) {
    char cmd[RX_LINE_MAX + 1];
    uint32_t n = rx_len;
    while (n && (rx_line[n - 1] == '\n' || rx_line[n - 1] == '\r')) --n;
    for (uint32_t i = 0; i < n; ++i) cmd[i] = rx_line[i];
    cmd[n] = 0;
    if (!ui_command(cmd) && !qse_imgtx_command(cmd, now) && qse_ble_tx_put((const uint8_t *)rx_line, rx_len))
        ++qse_ble_tx_drops;
    rx_len = 0;
}

static void rx_poll(uint64_t now) {
    while (uart_readOccupancy(BLE_UART)) {
        char c = (char)read_u32(BLE_UART + UART_DATA);
        ++qse_ble_rx_bytes;
        rx_line[rx_len++] = c;
        rx_last = now;
        if (c == '\n' || rx_len == RX_LINE_MAX) rx_dispatch(now);
    }
    if (rx_len && now - rx_last >= RX_GAP_TICKS) rx_dispatch(now);
}

void qse_ble_init(uint64_t now) {
    Uart_Config cfg;
    cfg.dataLength = BITS_8;
    cfg.parity = NONE;
    cfg.stop = ONE;
    cfg.clockDivider = BSP_CLINT_HZ / (QSE_BLE_BAUD * 8u) - 1u;
    uart_applyConfig(BLE_UART, &cfg);
    tx_head = tx_tail = 0;
    tx_tokens = 0; tx_last = now;
    rx_len = 0;
    knob_pos = 0;
    qse_imgtx_init();
    send_pair("BOOT", 1);
}

void qse_ble_poll(uint64_t now) {
    rx_poll(now);
    qse_imgtx_poll(now);
    tx_drain(now);
}
