#pragma once
#include <stdint.h>

/* QSE daughter card: knob / KEY0 / KEY1 handling and BLE link on UART1.
 *
 * Firmware owns all three controls. It reads GPIO0 = {SW2, SW1, KEY1, KEY0}
 * (synchronised and polarity-normalised in RTL, keys: 1 = pressed), debounces them,
 * publishes the result to the display through VIDEO_UI_SHADOW / VIDEO_CFG_APPLY, and
 * sends one ASCII line (terminated by "\r\n") on UART1 per event:
 *   KNOB,<0..3>   knob moved to a new position
 *   OSD,<0|1>     KEY0 pressed; 1 = text OSD on
 *   VIEW,<0|1>    KEY1 pressed; 1 = original|style compare, 0 = single style view
 *
 * Received bytes are collected into lines (ended by '\n', a 50 ms gap or 64 bytes).
 * Shortcut commands (each answered with the resulting state line above):
 *   VIEW | VIEW,<0|1>     toggle / set the compare view (same as KEY1)
 *   OSD  | OSD,<0|1>      toggle / set the text OSD (same as KEY0)
 *   KNOB,<0..3>           select the knob position (style label) until the physical
 *                         knob next changes position
 *   RATE | RATE,<B/s>     read / set the output rate limit (QSE_BLE_RATE_MIN..MAX)
 *   STATE                 report KNOB, OSD, VIEW and RATE
 * Image-transfer commands (see qse_imgtx.h) are executed; every other line is echoed
 * back unchanged, byte for byte.
 *
 * All output goes through one software queue. Each line or image packet is queued
 * whole, so event lines never split an image packet, and nothing blocks the main loop.
 * The queue drains at no more than qse_ble_rate bytes per second: the BLE module has no
 * flow control, and writing at the full UART rate overflows its buffer and drops bytes.
 */

/* BLE module baud rate on UART1 (GPIOL_06 RX / GPIOR_13 TX). Override with -DQSE_BLE_BAUD=... */
#ifndef QSE_BLE_BAUD
#define QSE_BLE_BAUD 128000u
#endif

/* Output rate limit in bytes per second (default, and the RATE command range). */
#ifndef QSE_BLE_RATE
#define QSE_BLE_RATE 1500u
#endif
#define QSE_BLE_RATE_MIN 200u
#define QSE_BLE_RATE_MAX 12800u

/* Debounce time for the GPIO0 inputs, in milliseconds. */
#ifndef QSE_BLE_DEBOUNCE_MS
#define QSE_BLE_DEBOUNCE_MS 20u
#endif

/* Diagnostics, visible in the IDE. */
extern volatile uint32_t qse_ble_knob;     /* debounced knob position 0..3 */
extern volatile uint32_t qse_ble_osd_on;   /* KEY0 state */
extern volatile uint32_t qse_ble_compare;  /* KEY1 state */
extern volatile uint32_t qse_ble_tx_msgs;  /* text lines queued */
extern volatile uint32_t qse_ble_rx_bytes; /* bytes received */
extern volatile uint32_t qse_ble_tx_drops; /* lines dropped because the queue was full */
extern volatile uint32_t qse_ble_rate;     /* current output rate limit, bytes per second */

void qse_ble_init(uint64_t now);
void qse_ble_poll(uint64_t now);  /* call every main-loop iteration */

/* Output queue, shared with the image sender. */
uint32_t qse_ble_tx_space(void);
uint32_t qse_ble_tx_pending(void);  /* queued bytes not yet written to the UART */
int qse_ble_tx_put(const uint8_t *data, uint32_t len);  /* all or nothing; -1 if full */
void qse_ble_send_line(const char *s);                  /* appends "\r\n" */
