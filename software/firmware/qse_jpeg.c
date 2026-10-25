#include "qse_jpeg.h"

/* Tables from ITU-T T.81 Annex K. */
static const uint8_t zigzag[64] = {
     0, 1, 8,16, 9, 2, 3,10,17,24,32,25,18,11, 4, 5,12,19,26,33,40,48,41,34,27,20,13, 6, 7,14,21,28,
    35,42,49,56,57,50,43,36,29,22,15,23,30,37,44,51,58,59,52,45,38,31,39,46,53,60,61,54,47,55,62,63
};
static const uint8_t base_q[2][64] = {
    {16,11,10,16,24,40,51,61, 12,12,14,19,26,58,60,55, 14,13,16,24,40,57,69,56, 14,17,22,29,51,87,80,62,
     18,22,37,56,68,109,103,77, 24,35,55,64,81,104,113,92, 49,64,78,87,103,121,120,101, 72,92,95,98,112,100,103,99},
    {17,18,24,47,99,99,99,99, 18,21,26,66,99,99,99,99, 24,26,56,99,99,99,99,99, 47,66,99,99,99,99,99,99,
     99,99,99,99,99,99,99,99, 99,99,99,99,99,99,99,99, 99,99,99,99,99,99,99,99, 99,99,99,99,99,99,99,99}
};
static const uint8_t dc_bits[2][16] = {
    {0,1,5,1,1,1,1,1,1,0,0,0,0,0,0,0}, {0,3,1,1,1,1,1,1,1,1,1,0,0,0,0,0}
};
static const uint8_t ac_bits[2][16] = {
    {0,2,1,3,3,2,4,3,5,5,4,4,0,0,1,0x7d}, {0,2,1,2,4,4,3,4,7,5,4,4,0,1,2,0x77}
};
static const uint8_t ac_vals[2][162] = {
    {0x01,0x02,0x03,0x00,0x04,0x11,0x05,0x12,0x21,0x31,0x41,0x06,0x13,0x51,0x61,0x07,
     0x22,0x71,0x14,0x32,0x81,0x91,0xa1,0x08,0x23,0x42,0xb1,0xc1,0x15,0x52,0xd1,0xf0,
     0x24,0x33,0x62,0x72,0x82,0x09,0x0a,0x16,0x17,0x18,0x19,0x1a,0x25,0x26,0x27,0x28,
     0x29,0x2a,0x34,0x35,0x36,0x37,0x38,0x39,0x3a,0x43,0x44,0x45,0x46,0x47,0x48,0x49,
     0x4a,0x53,0x54,0x55,0x56,0x57,0x58,0x59,0x5a,0x63,0x64,0x65,0x66,0x67,0x68,0x69,
     0x6a,0x73,0x74,0x75,0x76,0x77,0x78,0x79,0x7a,0x83,0x84,0x85,0x86,0x87,0x88,0x89,
     0x8a,0x92,0x93,0x94,0x95,0x96,0x97,0x98,0x99,0x9a,0xa2,0xa3,0xa4,0xa5,0xa6,0xa7,
     0xa8,0xa9,0xaa,0xb2,0xb3,0xb4,0xb5,0xb6,0xb7,0xb8,0xb9,0xba,0xc2,0xc3,0xc4,0xc5,
     0xc6,0xc7,0xc8,0xc9,0xca,0xd2,0xd3,0xd4,0xd5,0xd6,0xd7,0xd8,0xd9,0xda,0xe1,0xe2,
     0xe3,0xe4,0xe5,0xe6,0xe7,0xe8,0xe9,0xea,0xf1,0xf2,0xf3,0xf4,0xf5,0xf6,0xf7,0xf8,
     0xf9,0xfa},
    {0x00,0x01,0x02,0x03,0x11,0x04,0x05,0x21,0x31,0x06,0x12,0x41,0x51,0x07,0x61,0x71,
     0x13,0x22,0x32,0x81,0x08,0x14,0x42,0x91,0xa1,0xb1,0xc1,0x09,0x23,0x33,0x52,0xf0,
     0x15,0x62,0x72,0xd1,0x0a,0x16,0x24,0x34,0xe1,0x25,0xf1,0x17,0x18,0x19,0x1a,0x26,
     0x27,0x28,0x29,0x2a,0x35,0x36,0x37,0x38,0x39,0x3a,0x43,0x44,0x45,0x46,0x47,0x48,
     0x49,0x4a,0x53,0x54,0x55,0x56,0x57,0x58,0x59,0x5a,0x63,0x64,0x65,0x66,0x67,0x68,
     0x69,0x6a,0x73,0x74,0x75,0x76,0x77,0x78,0x79,0x7a,0x82,0x83,0x84,0x85,0x86,0x87,
     0x88,0x89,0x8a,0x92,0x93,0x94,0x95,0x96,0x97,0x98,0x99,0x9a,0xa2,0xa3,0xa4,0xa5,
     0xa6,0xa7,0xa8,0xa9,0xaa,0xb2,0xb3,0xb4,0xb5,0xb6,0xb7,0xb8,0xb9,0xba,0xc2,0xc3,
     0xc4,0xc5,0xc6,0xc7,0xc8,0xc9,0xca,0xd2,0xd3,0xd4,0xd5,0xd6,0xd7,0xd8,0xd9,0xda,
     0xe2,0xe3,0xe4,0xe5,0xe6,0xe7,0xe8,0xe9,0xea,0xf2,0xf3,0xf4,0xf5,0xf6,0xf7,0xf8,
     0xf9,0xfa}
};
/* Orthonormal 8-point DCT-II basis, Q13. */
static const int16_t dct_c[8][8] = {
    {2896, 2896, 2896, 2896, 2896, 2896, 2896, 2896},
    {4017, 3406, 2276,  799, -799,-2276,-3406,-4017},
    {3784, 1567,-1567,-3784,-3784,-1567, 1567, 3784},
    {3406, -799,-4017,-2276, 2276, 4017,  799,-3406},
    {2896,-2896,-2896, 2896, 2896,-2896,-2896, 2896},
    {2276,-4017,  799, 3406,-3406, -799, 4017,-2276},
    {1567,-3784, 3784,-1567,-1567, 3784,-3784, 1567},
    { 799,-2276, 3406,-4017, 4017,-3406, 2276, -799},
};
static const uint32_t crc_nibble[16] = {
    0x00000000u,0x1db71064u,0x3b6e20c8u,0x26d930acu,0x76dc4190u,0x6b6b51f4u,0x4db26158u,0x5005713cu,
    0xedb88320u,0xf00f9344u,0xd6d6a3e8u,0xcb61b38cu,0x9b64c2b0u,0x86d3d2d4u,0xa00ae278u,0xbdbdf21cu
};

/* Huffman code/size per symbol: [table 0=luma 1=chroma] */
static uint16_t dc_code[2][12], ac_code[2][256];
static uint8_t dc_size[2][12], ac_size[2][256];

static void build_codes(const uint8_t *bits, const uint8_t *vals, uint16_t *code, uint8_t *size) {
    uint32_t c = 0, k = 0;
    for (uint32_t len = 1; len <= 16; ++len) {
        for (uint32_t i = 0; i < bits[len - 1]; ++i, ++k) {
            uint32_t v = vals ? vals[k] : k;
            code[v] = (uint16_t)c++;
            size[v] = (uint8_t)len;
        }
        c <<= 1;
    }
}

static void put_byte(qse_jpeg_t *j, uint32_t b) {
    if (j->len >= j->cap) { j->error = 1; return; }
    j->out[j->len++] = (uint8_t)b;
    uint32_t c = j->crc ^ (b & 0xffu);
    c = (c >> 4) ^ crc_nibble[c & 15u];
    j->crc = (c >> 4) ^ crc_nibble[c & 15u];
}
static void put_word(qse_jpeg_t *j, uint32_t w) { put_byte(j, w >> 8); put_byte(j, w & 0xffu); }

static void put_bits(qse_jpeg_t *j, uint32_t code, uint32_t size) {
    j->bitbuf = (j->bitbuf << size) | (code & ((1u << size) - 1u));
    j->bitcnt += size;
    while (j->bitcnt >= 8) {
        uint32_t b = (j->bitbuf >> (j->bitcnt - 8)) & 0xffu;
        put_byte(j, b);
        if (b == 0xffu) put_byte(j, 0);   /* byte stuffing */
        j->bitcnt -= 8;
    }
    j->bitbuf &= (1u << j->bitcnt) - 1u;
}

static void put_dht(qse_jpeg_t *j, uint32_t cls_id, const uint8_t *bits, const uint8_t *vals) {
    uint32_t n = 0;
    for (uint32_t i = 0; i < 16; ++i) n += bits[i];
    put_word(j, 0xffc4); put_word(j, 19 + n); put_byte(j, cls_id);
    for (uint32_t i = 0; i < 16; ++i) put_byte(j, bits[i]);
    for (uint32_t i = 0; i < n; ++i) put_byte(j, vals ? vals[i] : i);
}

int qse_jpeg_begin(qse_jpeg_t *j, uint32_t quality) {
    if (!j->w || (j->w & 15u) || !j->h || (j->h & 1u) || j->w > 4096u || j->h > 4096u) return -1;
    if (quality < 1u) quality = 1u;
    if (quality > 100u) quality = 100u;
    uint32_t scale = quality < 50u ? 5000u / quality : 200u - quality * 2u;
    for (uint32_t t = 0; t < 2; ++t)
        for (uint32_t i = 0; i < 64; ++i) {
            uint32_t q = (base_q[t][i] * scale + 50u) / 100u;
            j->q[t][i] = (uint16_t)(q < 1u ? 1u : q > 255u ? 255u : q);
        }
    for (uint32_t t = 0; t < 2; ++t) {
        build_codes(dc_bits[t], 0, dc_code[t], dc_size[t]);
        build_codes(ac_bits[t], ac_vals[t], ac_code[t], ac_size[t]);
    }
    j->len = 0; j->crc = 0xffffffffu; j->error = 0;
    j->bitbuf = 0; j->bitcnt = 0;
    j->dc[0] = j->dc[1] = j->dc[2] = 0;
    j->mcu = 0;
    j->mcus = (j->w / 16u) * ((j->h + 15u) / 16u);

    put_word(j, 0xffd8);
    /* JFIF APP0, 1:1 aspect */
    put_word(j, 0xffe0); put_word(j, 16);
    put_byte(j, 'J'); put_byte(j, 'F'); put_byte(j, 'I'); put_byte(j, 'F'); put_byte(j, 0);
    put_word(j, 0x0101); put_byte(j, 0); put_word(j, 1); put_word(j, 1); put_word(j, 0);
    for (uint32_t t = 0; t < 2; ++t) {
        put_word(j, 0xffdb); put_word(j, 67); put_byte(j, t);
        for (uint32_t k = 0; k < 64; ++k) put_byte(j, j->q[t][zigzag[k]]);
    }
    put_word(j, 0xffc0); put_word(j, 17); put_byte(j, 8);
    put_word(j, j->h); put_word(j, j->w); put_byte(j, 3);
    put_byte(j, 1); put_byte(j, 0x22); put_byte(j, 0);
    put_byte(j, 2); put_byte(j, 0x11); put_byte(j, 1);
    put_byte(j, 3); put_byte(j, 0x11); put_byte(j, 1);
    put_dht(j, 0x00, dc_bits[0], 0);
    put_dht(j, 0x10, ac_bits[0], ac_vals[0]);
    put_dht(j, 0x01, dc_bits[1], 0);
    put_dht(j, 0x11, ac_bits[1], ac_vals[1]);
    put_word(j, 0xffda); put_word(j, 12); put_byte(j, 3);
    put_byte(j, 1); put_byte(j, 0x00);
    put_byte(j, 2); put_byte(j, 0x11);
    put_byte(j, 3); put_byte(j, 0x11);
    put_byte(j, 0); put_byte(j, 63); put_byte(j, 0);
    return j->error ? -1 : 0;
}

static uint32_t category(int32_t v) {
    uint32_t a = (uint32_t)(v < 0 ? -v : v), n = 0;
    while (a) { ++n; a >>= 1; }
    return n;
}

/* Encode one 8x8 block whose top-left is (x0,y0) in a plane of pw x ph.
 * Rows and columns past the plane edge repeat the last one. */
static void encode_block(qse_jpeg_t *j, const uint8_t *plane, uint32_t pw, uint32_t ph,
                         uint32_t x0, uint32_t y0, uint32_t comp) {
    int32_t s[8][8], t[8][8];
    uint32_t tab = comp ? 1u : 0u;
    for (uint32_t y = 0; y < 8; ++y) {
        uint32_t py = y0 + y < ph ? y0 + y : ph - 1u;
        const uint8_t *row = plane + py * pw;
        for (uint32_t x = 0; x < 8; ++x) {
            uint32_t px = x0 + x < pw ? x0 + x : pw - 1u;
            s[y][x] = (int32_t)row[px] - 128;
        }
    }
    /* Rows: Q13 basis, keep 2 fraction bits. */
    for (uint32_t y = 0; y < 8; ++y)
        for (uint32_t u = 0; u < 8; ++u) {
            int32_t a = 0;
            for (uint32_t x = 0; x < 8; ++x) a += dct_c[u][x] * s[y][x];
            t[y][u] = (a + (1 << 10)) >> 11;
        }
    /* Columns, then quantise into s[v][u] (natural order). */
    for (uint32_t u = 0; u < 8; ++u)
        for (uint32_t v = 0; v < 8; ++v) {
            int32_t a = 0;
            for (uint32_t y = 0; y < 8; ++y) a += dct_c[v][y] * t[y][u];
            a = (a + (1 << 14)) >> 15;
            int32_t q = j->q[tab][v * 8 + u];
            s[v][u] = a >= 0 ? (a + q / 2) / q : -((-a + q / 2) / q);
        }
    const int32_t *c = &s[0][0];

    int32_t diff = c[0] - j->dc[comp];
    j->dc[comp] = c[0];
    uint32_t n = category(diff);
    put_bits(j, dc_code[tab][n], dc_size[tab][n]);
    if (n) put_bits(j, (uint32_t)(diff < 0 ? diff - 1 : diff), n);

    uint32_t run = 0;
    for (uint32_t k = 1; k < 64; ++k) {
        int32_t v = c[zigzag[k]];
        if (!v) { ++run; continue; }
        while (run > 15u) { put_bits(j, ac_code[tab][0xf0], ac_size[tab][0xf0]); run -= 16u; }
        n = category(v);
        uint32_t sym = (run << 4) | n;
        put_bits(j, ac_code[tab][sym], ac_size[tab][sym]);
        put_bits(j, (uint32_t)(v < 0 ? v - 1 : v), n);
        run = 0;
    }
    if (run) put_bits(j, ac_code[tab][0], ac_size[tab][0]);
}

int qse_jpeg_step(qse_jpeg_t *j) {
    if (j->error) return -1;
    if (j->mcu < j->mcus) {
        uint32_t cols = j->w / 16u;
        uint32_t mx = j->mcu % cols, my = j->mcu / cols;
        uint32_t cw = j->w / 2u, ch = j->h / 2u;
        for (uint32_t b = 0; b < 4; ++b)
            encode_block(j, j->y, j->w, j->h, mx * 16u + (b & 1u) * 8u, my * 16u + (b >> 1) * 8u, 0);
        encode_block(j, j->cb, cw, ch, mx * 8u, my * 8u, 1);
        encode_block(j, j->cr, cw, ch, mx * 8u, my * 8u, 2);
        ++j->mcu;
        if (j->mcu < j->mcus) return j->error ? -1 : 0;
        if (j->bitcnt) put_bits(j, 0xffu, 8u - j->bitcnt);   /* pad with 1s */
        put_word(j, 0xffd9);
        j->crc = ~j->crc;
    }
    return j->error ? -1 : 1;
}
