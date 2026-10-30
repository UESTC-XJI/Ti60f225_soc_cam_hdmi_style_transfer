#pragma once
#include <stdint.h>

/* QSE controls and BLE on B's UART0 (128000 8N1).
 * RX=GPIOL_06, TX=GPIOR_13. UART0 is dedicated to this protocol.
 * KEY0=GPIOL_11 toggles FPS OSD; KEY1=GPIOL_09 toggles compare/single view.
 * Keys are active-high, weak pulldown, synchronized in RTL, debounced here 20 ms.
 * The physical knob remains owned by main.c, with B's raw {SW2,SW1} mapping:
 *   0=rainbow bank4, 1=starry_old bank0, 2=red_v3_dc bank3, 3=hold.
 * Commands (newline, 50 ms idle gap, or 64 bytes ends a line):
 *   VIEW | VIEW,0|1|2       toggle/set compare (1), single style (0), original single (2)
 *   OSD  | OSD,0|1        toggle/set FPS overlay
 *   KNOB,0..3             B's raw knob mapping; next physical change takes over
 *   SLOT | SLOT,0..4      query/select B's actual weight bank
 *   STATE                 KNOB / SLOT / BANK,<id>,<name> / OSD / VIEW / RATE
 *   RATE | RATE,<B/s>     query/set output limit, default 1500 B/s
 *   SNAP[,320[,q[,win]]]  native 320x240 JPEG, q=1..100, win=1..8
 *   ACK,<n> | NAK,<n> | ABORT
 * Other lines are echoed unchanged. Text and binary share one paced TX queue.
 */

#ifndef QSE_BLE_BAUD
#define QSE_BLE_BAUD 128000u
#endif
#ifndef QSE_BLE_RATE
#define QSE_BLE_RATE 1500u
#endif
#ifndef QSE_BLE_DEBOUNCE_MS
#define QSE_BLE_DEBOUNCE_MS 20u
#endif
#define QSE_BLE_RATE_MIN 200u
#define QSE_BLE_RATE_MAX 12800u

extern volatile uint32_t qse_ble_tx_msgs;
extern volatile uint32_t qse_ble_rx_bytes;
extern volatile uint32_t qse_ble_tx_drops;
extern volatile uint32_t qse_ble_rate;
extern volatile uint32_t qse_ble_knob;
extern volatile uint32_t qse_ble_osd_on, qse_ble_compare;

void qse_ble_init(uint64_t now);
void qse_ble_poll(uint64_t now);          /* call every main-loop iteration */
void qse_ble_note_knob(uint32_t pos);     /* main.c reports a physical knob move */

uint32_t qse_ble_tx_space(void);
uint32_t qse_ble_tx_pending(void);        /* queued bytes not yet written */
int qse_ble_tx_put(const uint8_t *data, uint32_t len);  /* all or nothing */
void qse_ble_send_line(const char *s);                  /* appends "\r\n" */

/* Leave initial original view when a physical/remote style is selected. */
void qse_ble_activate_style(void);
