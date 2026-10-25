#include "bsp.h"
#include "gpio.h"
#include "video_regs.h"
#include "soc_video_driver.h"
#include "qse_ble.h"
#include "qse_imgtx.h"

#define BLE_UART SYSTEM_UART_1_IO_CTRL
#define DEBOUNCE_TICKS ((uint64_t)BSP_CLINT_HZ * QSE_BLE_DEBOUNCE_MS / 1000u)
#define RX_GAP_TICKS ((uint64_t)BSP_CLINT_HZ / 20u)   /* 50 ms without a byte ends a line */
#define RX_LINE_MAX 64u
#define TX_QUEUE 1024u                                /* power of two */
#define TX_BURST 20u                                  /* one BLE notification */
#define HZ ((uint64_t)BSP_CLINT_HZ)

volatile uint32_t qse_ble_knob, qse_ble_osd_on = 1, qse_ble_compare = 1, qse_ble_tx_msgs, qse_ble_rx_bytes;
volatile uint32_t qse_ble_tx_drops, qse_ble_rate = QSE_BLE_RATE;

static uint32_t ui_pending;    /* a display-config publish is waiting */

typedef struct { uint32_t stable, candidate; uint64_t since; } debounce_t;
static debounce_t db_knob, db_key0, db_key1;

static uint8_t tx_queue[TX_QUEUE];
static uint32_t tx_head, tx_tail;  /* free-running; head - tail = queued bytes */
static uint32_t tx_tokens;         /* bytes allowed out now */
static uint64_t tx_last;           /* time up to which tokens were credited */
static int32_t knob_override = -1; /* KNOB,<n> from BLE; cleared by the next physical knob change */

static char rx_line[RX_LINE_MAX];
static uint32_t rx_len;
static uint64_t rx_last;

uint32_t qse_ble_tx_space(void) { return TX_QUEUE - (tx_head - tx_tail); }
uint32_t qse_ble_tx_pending(void) { return tx_head - tx_tail; }

static char *put_dec(char *p, uint32_t v) {
    char r[10]; uint32_t n = 0;
    do { r[n++] = (char)('0' + v % 10u); v /= 10u; } while (v);
    while (n) *p++ = r[--n];
    return p;
}
static void send_pair(const char *tag, uint32_t v) {
    char m[24], *p = m;
    while (*tag) *p++ = *tag++;
    *p++ = ',';
    *put_dec(p, v) = 0;
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

/* Token bucket: the module has no flow control, so the UART never runs ahead of
 * what the BLE link can carry (qse_ble_rate bytes per second, burst TX_BURST). */
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

static uint32_t knob_value(void) { return knob_override >= 0 ? (uint32_t)knob_override : db_knob.stable; }

static void set_view(uint32_t on) { qse_ble_compare = on & 1u; ui_pending = 1; send_pair("VIEW", qse_ble_compare); }
static void set_osd(uint32_t on) { qse_ble_osd_on = on & 1u; osd_set_user_enable(qse_ble_osd_on); send_pair("OSD", qse_ble_osd_on); }

/* Shortcut commands. Returns 1 if the line was one. */
static int ui_command(const char *c) {
    uint32_t v;
    if (c[0] == 'V' && c[1] == 'I' && c[2] == 'E' && c[3] == 'W') {
        if (!c[4]) { set_view(qse_ble_compare ^ 1u); return 1; }
        if (c[4] == ',' && !parse_uint(c + 5, &v) && v <= 1u) { set_view(v); return 1; }
    } else if (c[0] == 'O' && c[1] == 'S' && c[2] == 'D') {
        if (!c[3]) { set_osd(qse_ble_osd_on ^ 1u); return 1; }
        if (c[3] == ',' && !parse_uint(c + 4, &v) && v <= 1u) { set_osd(v); return 1; }
    } else if (c[0] == 'K' && c[1] == 'N' && c[2] == 'O' && c[3] == 'B' && c[4] == ',') {
        if (!parse_uint(c + 5, &v) && v <= 3u) {
            knob_override = (int32_t)v; qse_ble_knob = v; ui_pending = 1;
            send_pair("KNOB", v);
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
        send_pair("KNOB", knob_value());
        send_pair("OSD", qse_ble_osd_on);
        send_pair("VIEW", qse_ble_compare);
        send_pair("RATE", qse_ble_rate);
        return 1;
    }
    return 0;
}

/* A complete received line: commands are executed, anything else is echoed as received. */
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

/* {SW2,SW1} Gray code 00,01,11,10 -> 0,1,2,3 */
static uint32_t knob_decode(uint32_t g) {
    switch ((g >> 2) & 3u) {
    case 0: return 0;
    case 1: return 1;
    case 3: return 2;
    default: return 3;
    }
}

/* Returns 1 when the debounced value changes. */
static int debounce(debounce_t *d, uint32_t raw, uint64_t now) {
    if (raw != d->candidate) { d->candidate = raw; d->since = now; return 0; }
    if (raw != d->stable && now - d->since >= DEBOUNCE_TICKS) { d->stable = raw; return 1; }
    return 0;
}

static void db_start(debounce_t *d, uint32_t raw, uint64_t now) {
    d->stable = d->candidate = raw; d->since = now;
}

void qse_ble_init(uint64_t now) {
    Uart_Config cfg;
    cfg.dataLength = BITS_8;
    cfg.parity = NONE;
    cfg.stop = ONE;
    cfg.clockDivider = BSP_CLINT_HZ / (QSE_BLE_BAUD * 8u) - 1u;
    uart_applyConfig(BLE_UART, &cfg);

    uint32_t g = gpio_getInput(SYSTEM_GPIO_0_IO_CTRL);
    db_start(&db_knob, knob_decode(g), now);
    db_start(&db_key0, g & 1u, now);
    db_start(&db_key1, (g >> 1) & 1u, now);
    qse_ble_knob = db_knob.stable;
    qse_ble_osd_on = 1;
    qse_ble_compare = 1;
    osd_set_user_enable(1);
    ui_pending = 1;   /* publish initial knob label and compare view */
    tx_head = tx_tail = 0;
    tx_tokens = 0; tx_last = now;
    knob_override = -1;
    rx_len = 0;
    qse_imgtx_init();
}

void qse_ble_poll(uint64_t now) {
    rx_poll(now);

    uint32_t g = gpio_getInput(SYSTEM_GPIO_0_IO_CTRL);

    if (debounce(&db_knob, knob_decode(g), now)) {
        knob_override = -1;           /* the physical knob takes over again */
        qse_ble_knob = db_knob.stable;
        ui_pending = 1;
        send_pair("KNOB", db_knob.stable);
    }
    /* KEY0: text OSD only; KEY1: compare / single view. */
    if (debounce(&db_key0, g & 1u, now) && db_key0.stable) set_osd(qse_ble_osd_on ^ 1u);
    if (debounce(&db_key1, (g >> 1) & 1u, now) && db_key1.stable) set_view(qse_ble_compare ^ 1u);

    /* One display-config apply publishes view mode and knob label together
     * at the next display frame start. Retried while a previous apply is still in flight. */
    if (ui_pending && !(video_read(VIDEO_CFG_STATUS) & 2u)) {
        video_write(VIDEO_UI_SHADOW, (qse_ble_compare & 1u) | (knob_value() << 1));
        video_write(VIDEO_CFG_APPLY, 2u);
        ui_pending = 0;
    }

    qse_imgtx_poll(now);
    tx_drain(now);
}
