#include "bsp.h"
#include "style_driver.h"
#include "qse_ble.h"
#include "qse_jpeg.h"
#include "qse_imgtx.h"

#define SRC_W 320u
#define SRC_H 240u
#define RESULT_OFFSET 0x00800000u
#define SLOT_BYTES 0x00140000u
#define RAW_BASE 0x05000000u

/* Work buffers in the CPU DDR window 0x01000000..0x010fffff (boot DDR test only). */
#define PLANE_Y  ((uint8_t *)0x01000000u)
#define PLANE_CB ((uint8_t *)0x0104b000u)
#define PLANE_CR ((uint8_t *)0x0105dc00u)
#define JPEG_OUT ((uint8_t *)0x01080000u)
#define JPEG_CAP 0x00080000u

#define PAYLOAD 128u
#define HZ ((uint64_t)BSP_CLINT_HZ)
#define PAUSE_TIMEOUT (HZ)            /* in-flight inference must finish within 1 s */
#define SETTLE_TICKS (HZ / 20u)       /* 3 display frames: last result reaches HDMI */
#define ACK_TIMEOUT (HZ * 8u / 10u)
#define MAX_RETRIES 8u

enum { IDLE, PAUSE, SETTLE, COPY, ENCODE, HEADER, SEND };

volatile uint32_t qse_imgtx_state, qse_imgtx_images, qse_imgtx_errors;
volatile uint32_t qse_imgtx_resends, qse_imgtx_jpeg_bytes;

static qse_jpeg_t jpg;
static uint32_t out_w, out_h, factor, quality, window;
static uint32_t row, packets, base, next, retries;
static int slot;
static uint64_t since;

static void sync_ddr(void) { __asm__ volatile("fence rw,rw\n.word 0x0000500f" ::: "memory"); }

static char *put_text(char *p, const char *s) { while (*s) *p++ = *s++; return p; }
static char *put_dec(char *p, uint32_t v) {
    char r[10]; uint32_t n = 0;
    do { r[n++] = (char)('0' + v % 10u); v /= 10u; } while (v);
    while (n) *p++ = r[--n];
    return p;
}
static char *put_hex(char *p, uint32_t v) {
    for (int i = 7; i >= 0; --i) { uint32_t d = (v >> (i * 4)) & 15u; *p++ = (char)(d < 10u ? '0' + d : 'a' + d - 10u); }
    return p;
}

static void fail(const char *why) {
    char m[32];
    char *p = put_text(put_text(m, "IMG,ERR,"), why);
    *p = 0;
    if (qse_imgtx_state >= PAUSE && qse_imgtx_state <= COPY) style_stream_set(1);
    qse_imgtx_state = IDLE;
    ++qse_imgtx_errors;
    qse_ble_send_line(m);
}

/* Parses ",<n>" at *s; leaves *v unchanged if absent. Returns -1 on junk. */
static int parse_arg(const char **s, uint32_t *v) {
    if (!**s) return 0;
    if (**s != ',') return -1;
    ++*s;
    uint32_t n = 0, digits = 0;
    while (**s >= '0' && **s <= '9' && digits < 6) { n = n * 10u + (uint32_t)(**s - '0'); ++*s; ++digits; }
    if (!digits || (**s && **s != ',')) return -1;
    *v = n;
    return 0;
}

static int starts(const char *s, const char *prefix, const char **rest) {
    while (*prefix) if (*s++ != *prefix++) return 0;
    *rest = s;
    return 1;
}

void qse_imgtx_init(void) { qse_imgtx_state = IDLE; }

int qse_imgtx_command(const char *line, uint64_t now) {
    const char *a;
    if (starts(line, "SNAP", &a)) {
        uint32_t w = 320u, q = 60u, win = 4u;
        if (qse_imgtx_state != IDLE) { qse_ble_send_line("IMG,ERR,BUSY"); return 1; }
        if (parse_arg(&a, &w) || parse_arg(&a, &q) || parse_arg(&a, &win) || *a ||
            (w != 160u && w != 320u) || q < 1u || q > 100u || win < 1u || win > 8u) {
            qse_ble_send_line("IMG,ERR,ARG");
            return 1;
        }
        out_w = w; out_h = w * 3u / 4u; factor = SRC_W / w; quality = q; window = win;
        style_stream_set(0);
        since = now;
        qse_imgtx_state = PAUSE;
        return 1;
    }
    if (starts(line, "ACK", &a) || starts(line, "NAK", &a)) {
        uint32_t n = 0xffffffffu;
        int nak = line[0] == 'N';
        if (parse_arg(&a, &n) || *a || n == 0xffffffffu) return 1;
        if (qse_imgtx_state != SEND) return 1;
        if (n > base && n <= next) { base = n; retries = 0; since = now; }
        if (nak && n >= base && n < next) { next = n; ++qse_imgtx_resends; }
        if (base == packets) {
            qse_imgtx_state = IDLE;
            ++qse_imgtx_images;
            qse_ble_send_line("IMG,END");
        }
        return 1;
    }
    if (starts(line, "ABORT", &a) && !*a) {
        if (qse_imgtx_state != IDLE) fail("ABORT");
        return 1;
    }
    return 0;
}

/* Two output rows (one chroma row) per call; each output pixel averages factor x factor sources. */
static void copy_rows(void) {
    const volatile uint32_t *src = (const volatile uint32_t *)(RAW_BASE + (uint32_t)slot * SLOT_BYTES + RESULT_OFFSET);
    uint32_t cw = out_w / 2u, shift = factor == 1u ? 0u : factor == 2u ? 2u : 4u;
    for (uint32_t cx = 0; cx < cw; ++cx) {
        uint32_t rs = 0, gs = 0, bs = 0;
        for (uint32_t k = 0; k < 4; ++k) {
            uint32_t ox = cx * 2u + (k & 1u), oy = row + (k >> 1);
            uint32_t r = 0, g = 0, b = 0;
            for (uint32_t sy = 0; sy < factor; ++sy) {
                const volatile uint32_t *p = src + (oy * factor + sy) * SRC_W + ox * factor;
                for (uint32_t sx = 0; sx < factor; ++sx) {
                    uint32_t v = p[sx];
                    r += v & 255u; g += (v >> 8) & 255u; b += (v >> 16) & 255u;
                }
            }
            r >>= shift; g >>= shift; b >>= shift;
            PLANE_Y[oy * out_w + ox] = (uint8_t)((77u * r + 150u * g + 29u * b + 128u) >> 8);
            rs += r; gs += g; bs += b;
        }
        int32_t cb = (int32_t)(128u * 4u * 256u + 128u * bs + 512u) - (int32_t)(43u * rs + 85u * gs);
        int32_t cr = (int32_t)(128u * 4u * 256u + 128u * rs + 512u) - (int32_t)(107u * gs + 21u * bs);
        PLANE_CB[(row / 2u) * cw + cx] = (uint8_t)(cb >> 10);
        PLANE_CR[(row / 2u) * cw + cx] = (uint8_t)(cr >> 10);
    }
    row += 2u;
}

static int queue_packet(uint32_t seq) {
    uint8_t pkt[PAYLOAD + 7u];
    uint32_t off = seq * PAYLOAD, len = jpg.len - off < PAYLOAD ? jpg.len - off : PAYLOAD;
    if (qse_ble_tx_space() < len + 7u) return -1;
    pkt[0] = 0xa5; pkt[1] = 0x5a; pkt[2] = (uint8_t)seq; pkt[3] = (uint8_t)(seq >> 8); pkt[4] = (uint8_t)len;
    for (uint32_t i = 0; i < len; ++i) pkt[5 + i] = JPEG_OUT[off + i];
    uint32_t crc = 0xffffu;
    for (uint32_t i = 2; i < len + 5u; ++i) {
        crc ^= (uint32_t)pkt[i] << 8;
        for (uint32_t b = 0; b < 8; ++b) crc = crc & 0x8000u ? ((crc << 1) ^ 0x1021u) & 0xffffu : (crc << 1) & 0xffffu;
    }
    pkt[len + 5u] = (uint8_t)crc; pkt[len + 6u] = (uint8_t)(crc >> 8);
    return qse_ble_tx_put(pkt, len + 7u);
}

void qse_imgtx_poll(uint64_t now) {
    switch (qse_imgtx_state) {
    case PAUSE:
        if (!style_busy()) { since = now; qse_imgtx_state = SETTLE; }
        else if (now - since >= PAUSE_TIMEOUT) fail("TIMEOUT");
        break;
    case SETTLE:
        if (now - since < SETTLE_TICKS) break;
        slot = style_display_slot();
        if (slot == -2) { fail("BITSTREAM"); break; }
        if (slot < 0) { fail("NOSLOT"); break; }
        sync_ddr();   /* drop lines cached by an earlier snapshot */
        row = 0;
        qse_imgtx_state = COPY;
        break;
    case COPY:
        copy_rows();
        if (row < out_h) break;
        if (style_display_slot() != slot) { fail("MOVED"); break; }
        style_stream_set(1);
        jpg.y = PLANE_Y; jpg.cb = PLANE_CB; jpg.cr = PLANE_CR;
        jpg.w = out_w; jpg.h = out_h; jpg.out = JPEG_OUT; jpg.cap = JPEG_CAP;
        qse_imgtx_state = ENCODE;
        if (qse_jpeg_begin(&jpg, quality)) fail("JPEG");
        break;
    case ENCODE: {
        int rc = qse_jpeg_step(&jpg);
        if (rc < 0) { fail("JPEG"); break; }
        if (rc == 0) break;
        qse_imgtx_jpeg_bytes = jpg.len;
        packets = (jpg.len + PAYLOAD - 1u) / PAYLOAD;
        base = next = retries = 0;
        qse_imgtx_state = HEADER;
        break;
    }
    case HEADER: {
        char m[64];
        char *p = put_text(m, "IMG,");
        p = put_dec(p, out_w); *p++ = ',';
        p = put_dec(p, out_h); *p++ = ',';
        p = put_dec(p, jpg.len); *p++ = ',';
        p = put_hex(p, jpg.crc); *p++ = ',';
        p = put_dec(p, packets); *p = 0;
        if (qse_ble_tx_space() < 64u) break;
        qse_ble_send_line(m);
        since = now;
        qse_imgtx_state = SEND;
        break;
    }
    case SEND:
        /* At most one packet waits in the queue, so a NAK or timeout wastes little. */
        while (next < packets && next < base + window && qse_ble_tx_pending() < 8u && !queue_packet(next)) ++next;
        if (now - since >= ACK_TIMEOUT + (uint64_t)window * (PAYLOAD + 7u) * HZ / qse_ble_rate) {
            if (++retries > MAX_RETRIES) { fail("TIMEOUT"); break; }
            next = base;
            since = now;
            ++qse_imgtx_resends;
        }
        break;
    default:
        break;
    }
}
