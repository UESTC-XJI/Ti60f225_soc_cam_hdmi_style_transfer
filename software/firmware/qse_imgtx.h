#pragma once
#include <stdint.h>

/* BLE snapshot of the style-transfer result, sent as a baseline JPEG over UART1.
 *
 * Commands (one ASCII line each, from the phone/browser):
 *   SNAP[,<w>[,<q>[,<win>]]]  w = 160|320|640 (default 320), JPEG quality 1..100
 *                             (default 60), send window 1..8 packets (default 4)
 *   ACK,<n>                   cumulative: every packet with seq < n arrived
 *   NAK,<n>                   resend from packet n (go-back-N)
 *   ABORT                     stop the transfer
 *
 * Replies:
 *   IMG,<w>,<h>,<bytes>,<crc32 hex>,<packets>   JPEG header, sent before the packets
 *   packet: A5 5A seq(u16 LE) len(u8) payload[len] crc16(u16 LE)
 *           crc16 = CRC-16/CCITT-FALSE over seq, len and payload
 *   IMG,END                                    every packet acknowledged
 *   IMG,ERR,<BUSY|NOSLOT|MOVED|JPEG|TIMEOUT|ABORT|ARG|BITSTREAM>
 *
 * Source: the 640x480 style result of the slot currently on HDMI
 * (raw slot base + 0x800000, one 32-bit word per pixel, R = bits 7:0, G = 15:8, B = 23:16).
 * The CNN stream pauses while the frame is read (inference finish + ~50 ms + copy),
 * so the displayed slot cannot change; HDMI keeps showing that frame meanwhile.
 * Needs the bitstream with the style register 0x88 slot readback.
 */

/* Diagnostics, visible in the IDE. */
extern volatile uint32_t qse_imgtx_state, qse_imgtx_images, qse_imgtx_errors;
extern volatile uint32_t qse_imgtx_resends, qse_imgtx_jpeg_bytes;

void qse_imgtx_init(void);
/* Returns 1 if the line was an image command (and must not be echoed). */
int qse_imgtx_command(const char *line, uint64_t now);
void qse_imgtx_poll(uint64_t now);
