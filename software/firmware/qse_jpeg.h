#pragma once
#include <stdint.h>

/* Baseline JPEG encoder: YCbCr 4:2:0, Annex K Huffman tables, integer DCT.
 * Works incrementally so the main loop keeps running: begin() writes the
 * headers, every step() encodes one 16x16 MCU and the last one writes EOI.
 *
 * Input planes: y is w*h bytes, cb and cr are (w/2)*(h/2) bytes.
 * w must be a multiple of 16; h only needs to be even (bottom rows repeat). */
typedef struct {
    const uint8_t *y, *cb, *cr;
    uint32_t w, h;
    uint8_t *out;
    uint32_t cap, len, crc;   /* crc: CRC-32 (IEEE) of out[0..len) */
    uint32_t mcu, mcus;
    int32_t dc[3];
    uint32_t bitbuf, bitcnt;
    int error;                /* output buffer overflow */
    uint16_t q[2][64];        /* quantisers, natural order */
} qse_jpeg_t;

/* quality 1..100 (IJG scaling). Returns 0, or -1 on bad geometry or overflow. */
int qse_jpeg_begin(qse_jpeg_t *j, uint32_t quality);
/* Returns 0 while more MCUs remain, 1 when the file is complete, -1 on overflow. */
int qse_jpeg_step(qse_jpeg_t *j);
