#pragma once
#include <stdint.h>

/* BLE link on UART0, repurposed as the QSE daughter-card channel.
 *
 * Pins: GPIOL_06 = RX (input, weak pullup), GPIOR_13 = TX (output), 3.3 V.
 * Baud 128000 8N1. The debug console is gone on this build; every byte on the
 * port belongs to the BLE protocol, so nothing else may write to UART0.
 *
 * Received lines (ended by '\n', a 50 ms gap or 64 bytes):
 *   STATE                 -> KNOB,<0..3> / BANK,<k>,<name> / RATE,<B/s>
 *   KNOB,<0..3>           -> same mapping as the physical knob, replies KNOB/BANK
 *   RATE | RATE,<B/s>     -> read / set the output rate limit
 *   SNAP[,<w>[,<q>[,<win>]]]  image snapshot (w = 160|320, default 320)
 *   ACK,<n> | NAK,<n> | ABORT
 * Anything else is echoed back unchanged.
 *
 * The output queue drains at qse_ble_rate bytes/s because the BLE module has no
 * flow control; at the default 1500 B/s a snapshot takes seconds by design.
 */

#ifndef QSE_BLE_BAUD
#define QSE_BLE_BAUD 128000u
#endif
#ifndef QSE_BLE_RATE
#define QSE_BLE_RATE 1500u
#endif
#define QSE_BLE_RATE_MIN 200u
#define QSE_BLE_RATE_MAX 12800u

extern volatile uint32_t qse_ble_tx_msgs;
extern volatile uint32_t qse_ble_rx_bytes;
extern volatile uint32_t qse_ble_tx_drops;
extern volatile uint32_t qse_ble_rate;
extern volatile uint32_t qse_ble_knob;

void qse_ble_init(uint64_t now);
void qse_ble_poll(uint64_t now);          /* call every main-loop iteration */
void qse_ble_note_knob(uint32_t pos);     /* main.c reports a physical knob move */

uint32_t qse_ble_tx_space(void);
uint32_t qse_ble_tx_pending(void);        /* queued bytes not yet written */
int qse_ble_tx_put(const uint8_t *data, uint32_t len);  /* all or nothing */
void qse_ble_send_line(const char *s);                  /* appends "\r\n" */
