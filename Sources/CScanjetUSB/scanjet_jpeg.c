#include "scanjet_jpeg.h"

#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define JPEG_MCU 16

struct ScanjetJPEGWriter {
    FILE *file;
    uint32_t width;
    uint32_t height;
    uint32_t rows;
    int spp;
    int mcu_w;
    int mcu_h;
    int blocks_x;
    uint8_t qy[64];
    uint8_t qc[64];
    uint8_t *line[JPEG_MCU];
    int buffered;
    uint32_t bitbuf;
    int bitcount;
    int dc_y;
    int dc_cb;
    int dc_cr;
    long sof_offset;
};

static char g_jpeg_error[256];
static float g_dct[8][8];
static int g_dct_ready;

static const uint8_t kZigzag[64] = {
    0,  1,  8, 16,  9,  2,  3, 10,
    17, 24, 32, 25, 18, 11,  4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13,  6,  7, 14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63
};

static const uint8_t kStdLumQuant[64] = {
    16, 11, 10, 16, 24, 40, 51, 61,
    12, 12, 14, 19, 26, 58, 60, 55,
    14, 13, 16, 24, 40, 57, 69, 56,
    14, 17, 22, 29, 51, 87, 80, 62,
    18, 22, 37, 56, 68,109,103, 77,
    24, 35, 55, 64, 81,104,113, 92,
    49, 64, 78, 87,103,121,120,101,
    72, 92, 95, 98,112,100,103, 99
};

static const uint8_t kStdChrQuant[64] = {
    17, 18, 24, 47, 99, 99, 99, 99,
    18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99,
    47, 66, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99
};

static const uint8_t kDcLumBits[17] = { 0, 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 };
static const uint8_t kDcLumVal[12] = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
static const uint8_t kAcLumBits[17] = { 0, 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d };
static const uint8_t kAcLumVal[162] = {
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
    0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
    0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
    0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa
};
static const uint8_t kDcChrBits[17] = { 0, 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0 };
static const uint8_t kDcChrVal[12] = { 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
static const uint8_t kAcChrBits[17] = { 0, 0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77 };
static const uint8_t kAcChrVal[162] = {
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
    0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
    0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
    0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
    0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
    0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
    0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
    0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
    0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
    0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa
};

static uint16_t g_dc_lum_code[12], g_dc_chr_code[12];
static uint8_t g_dc_lum_len[12], g_dc_chr_len[12];
static uint16_t g_ac_lum_code[256], g_ac_chr_code[256];
static uint8_t g_ac_lum_len[256], g_ac_chr_len[256];
static int g_tables_ready;

static void set_err(const char *msg)
{
    snprintf(g_jpeg_error, sizeof(g_jpeg_error), "%s", msg);
}

const char *scanjet_jpeg_last_error(void)
{
    return g_jpeg_error;
}

static void build_huff(const uint8_t *bits, const uint8_t *vals, uint16_t *codes, uint8_t *lens)
{
    uint16_t code = 0;
    int k = 0;
    for (int i = 1; i <= 16; i++) {
        for (int j = 0; j < bits[i]; j++) {
            uint8_t v = vals[k++];
            codes[v] = code;
            lens[v] = (uint8_t)i;
            code++;
        }
        code <<= 1;
    }
}

static void ensure_tables(void)
{
    if (g_tables_ready) return;
    memset(g_ac_lum_len, 0, sizeof(g_ac_lum_len));
    memset(g_ac_chr_len, 0, sizeof(g_ac_chr_len));
    build_huff(kDcLumBits, kDcLumVal, g_dc_lum_code, g_dc_lum_len);
    build_huff(kDcChrBits, kDcChrVal, g_dc_chr_code, g_dc_chr_len);
    build_huff(kAcLumBits, kAcLumVal, g_ac_lum_code, g_ac_lum_len);
    build_huff(kAcChrBits, kAcChrVal, g_ac_chr_code, g_ac_chr_len);
    for (int u = 0; u < 8; u++) {
        float s = u == 0 ? 0.35355339059f : 0.5f;
        for (int x = 0; x < 8; x++) {
            g_dct[u][x] = s * cosf((float)((2 * x + 1) * u) * (float)M_PI / 16.f);
        }
    }
    g_dct_ready = 1;
    g_tables_ready = 1;
}

static void scale_quant(uint8_t *dst, const uint8_t *src, int quality)
{
    int q = quality < 1 ? 1 : (quality > 100 ? 100 : quality);
    int scale = q < 50 ? 5000 / q : 200 - q * 2;
    for (int i = 0; i < 64; i++) {
        int v = (src[i] * scale + 50) / 100;
        if (v < 1) v = 1;
        if (v > 255) v = 255;
        dst[i] = (uint8_t)v;
    }
}

static int put_byte(ScanjetJPEGWriter *w, int b)
{
    if (fputc(b, w->file) == EOF) {
        set_err("cannot write JPEG");
        return -1;
    }
    return 0;
}

static int emit_bits(ScanjetJPEGWriter *w, uint32_t bits, int n)
{
    if (n <= 0) return 0;
    w->bitbuf = (w->bitbuf << n) | (bits & ((1u << n) - 1));
    w->bitcount += n;
    while (w->bitcount >= 8) {
        int b = (int)((w->bitbuf >> (w->bitcount - 8)) & 0xff);
        w->bitcount -= 8;
        if (put_byte(w, b) != 0) return -1;
        if (b == 0xff && put_byte(w, 0) != 0) return -1;
    }
    return 0;
}

static int flush_bits(ScanjetJPEGWriter *w)
{
    if (w->bitcount > 0) {
        uint32_t pad = (1u << (8 - w->bitcount)) - 1;
        if (emit_bits(w, pad, 8 - w->bitcount) != 0) return -1;
    }
    w->bitbuf = 0;
    w->bitcount = 0;
    return 0;
}

static int marker(ScanjetJPEGWriter *w, int code, const uint8_t *data, int len)
{
    if (put_byte(w, 0xff) != 0 || put_byte(w, code) != 0) return -1;
    int seglen = len + 2;
    if (put_byte(w, (seglen >> 8) & 0xff) != 0 || put_byte(w, seglen & 0xff) != 0) return -1;
    if (len > 0 && fwrite(data, 1, (size_t)len, w->file) != (size_t)len) {
        set_err("cannot write JPEG marker");
        return -1;
    }
    return 0;
}

static int write_dqt(ScanjetJPEGWriter *w, int id, const uint8_t *q)
{
    uint8_t buf[65];
    buf[0] = (uint8_t)id;
    for (int i = 0; i < 64; i++) buf[1 + i] = q[kZigzag[i]];
    return marker(w, 0xdb, buf, 65);
}

static int write_dht(ScanjetJPEGWriter *w, int cls_id, const uint8_t *bits, const uint8_t *vals, int nval)
{
    uint8_t buf[1 + 16 + 162];
    buf[0] = (uint8_t)cls_id;
    memcpy(buf + 1, bits + 1, 16);
    memcpy(buf + 17, vals, (size_t)nval);
    return marker(w, 0xc4, buf, 17 + nval);
}

static int category(int v)
{
    if (v == 0) return 0;
    if (v < 0) v = -v;
    int c = 0;
    while (v) { v >>= 1; c++; }
    return c;
}

static int emit_block(ScanjetJPEGWriter *w, const int *coef, int *dc_pred,
                      const uint16_t *dc_code, const uint8_t *dc_len,
                      const uint16_t *ac_code, const uint8_t *ac_len)
{
    int diff = coef[0] - *dc_pred;
    *dc_pred = coef[0];
    int cat = category(diff);
    if (dc_len[cat] == 0 && cat != 0) {
        set_err("JPEG DC Huffman missing");
        return -1;
    }
    if (emit_bits(w, dc_code[cat], dc_len[cat]) != 0) return -1;
    if (cat) {
        int bits = diff;
        if (bits < 0) bits += (1 << cat) - 1;
        if (emit_bits(w, (uint32_t)bits, cat) != 0) return -1;
    }

    int run = 0;
    for (int i = 1; i < 64; i++) {
        int v = coef[kZigzag[i]];
        if (v == 0) {
            run++;
            continue;
        }
        while (run >= 16) {
            if (emit_bits(w, ac_code[0xf0], ac_len[0xf0]) != 0) return -1;
            run -= 16;
        }
        cat = category(v);
        int rs = (run << 4) | cat;
        if (ac_len[rs] == 0) {
            set_err("JPEG AC Huffman missing");
            return -1;
        }
        if (emit_bits(w, ac_code[rs], ac_len[rs]) != 0) return -1;
        int bits = v;
        if (bits < 0) bits += (1 << cat) - 1;
        if (emit_bits(w, (uint32_t)bits, cat) != 0) return -1;
        run = 0;
    }
    if (run > 0) {
        if (emit_bits(w, ac_code[0x00], ac_len[0x00]) != 0) return -1;
    }
    return 0;
}

static void fdct8(const float *src, int *out, const uint8_t *q)
{
    float tmp[64];
    for (int y = 0; y < 8; y++) {
        for (int u = 0; u < 8; u++) {
            float s = 0;
            for (int x = 0; x < 8; x++) s += src[y * 8 + x] * g_dct[u][x];
            tmp[y * 8 + u] = s;
        }
    }
    for (int u = 0; u < 8; u++) {
        for (int v = 0; v < 8; v++) {
            float s = 0;
            for (int y = 0; y < 8; y++) s += tmp[y * 8 + u] * g_dct[v][y];
            int z = (int)lroundf(s / (float)q[v * 8 + u]);
            if (z < -1023) z = -1023;
            if (z > 1023) z = 1023;
            out[v * 8 + u] = z;
        }
    }
}

static uint8_t sample_px(ScanjetJPEGWriter *w, int x, int y, int ch)
{
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if ((uint32_t)x >= w->width) x = (int)w->width - 1;
    if (y >= w->buffered) y = w->buffered > 0 ? w->buffered - 1 : 0;
    if (w->spp == 1) return w->line[y][x];
    return w->line[y][x * 3 + ch];
}

static void load_y_block(ScanjetJPEGWriter *w, int bx, int by, float *block)
{
    for (int y = 0; y < 8; y++) {
        for (int x = 0; x < 8; x++) {
            int r, g, b;
            if (w->spp == 1) {
                r = g = b = sample_px(w, bx + x, by + y, 0);
            } else {
                r = sample_px(w, bx + x, by + y, 0);
                g = sample_px(w, bx + x, by + y, 1);
                b = sample_px(w, bx + x, by + y, 2);
            }
            block[y * 8 + x] = 0.299f * r + 0.587f * g + 0.114f * b - 128.f;
        }
    }
}

static void load_c_block(ScanjetJPEGWriter *w, int bx, int by, int cb, float *block)
{
    for (int y = 0; y < 8; y++) {
        for (int x = 0; x < 8; x++) {
            int sx = bx + x * 2;
            int sy = by + y * 2;
            float sum = 0;
            for (int dy = 0; dy < 2; dy++) {
                for (int dx = 0; dx < 2; dx++) {
                    int r = sample_px(w, sx + dx, sy + dy, 0);
                    int g = sample_px(w, sx + dx, sy + dy, 1);
                    int b = sample_px(w, sx + dx, sy + dy, 2);
                    if (cb) sum += -0.168736f * r - 0.331264f * g + 0.5f * b;
                    else sum += 0.5f * r - 0.418688f * g - 0.081312f * b;
                }
            }
            block[y * 8 + x] = sum * 0.25f;
        }
    }
}

static int encode_mcu_row(ScanjetJPEGWriter *w)
{
    int coef[64];
    float block[64];
    for (int mx = 0; mx < w->blocks_x; mx++) {
        if (w->spp == 1) {
            load_y_block(w, mx * 8, 0, block);
            fdct8(block, coef, w->qy);
            if (emit_block(w, coef, &w->dc_y, g_dc_lum_code, g_dc_lum_len,
                           g_ac_lum_code, g_ac_lum_len) != 0) return -1;
        } else {
            for (int by = 0; by < 2; by++) {
                for (int bx = 0; bx < 2; bx++) {
                    load_y_block(w, mx * 16 + bx * 8, by * 8, block);
                    fdct8(block, coef, w->qy);
                    if (emit_block(w, coef, &w->dc_y, g_dc_lum_code, g_dc_lum_len,
                                   g_ac_lum_code, g_ac_lum_len) != 0) return -1;
                }
            }
            load_c_block(w, mx * 16, 0, 1, block);
            fdct8(block, coef, w->qc);
            if (emit_block(w, coef, &w->dc_cb, g_dc_chr_code, g_dc_chr_len,
                           g_ac_chr_code, g_ac_chr_len) != 0) return -1;
            load_c_block(w, mx * 16, 0, 0, block);
            fdct8(block, coef, w->qc);
            if (emit_block(w, coef, &w->dc_cr, g_dc_chr_code, g_dc_chr_len,
                           g_ac_chr_code, g_ac_chr_len) != 0) return -1;
        }
    }
    return 0;
}

static int flush_mcu_rows(ScanjetJPEGWriter *w, int last)
{
    while (w->buffered >= w->mcu_h || (last && w->buffered > 0)) {
        if (w->buffered < w->mcu_h) {
            uint8_t *fill = w->line[w->buffered - 1];
            while (w->buffered < w->mcu_h) {
                memcpy(w->line[w->buffered], fill, (size_t)w->width * (size_t)w->spp);
                w->buffered++;
            }
        }
        if (encode_mcu_row(w) != 0) return -1;
        int keep = w->buffered - w->mcu_h;
        if (keep > 0) {
            for (int i = 0; i < keep; i++) {
                memcpy(w->line[i], w->line[i + w->mcu_h], (size_t)w->width * (size_t)w->spp);
            }
            w->buffered = keep;
        } else {
            w->buffered = 0;
        }
        if (!last) break;
    }
    return 0;
}

static void free_writer(ScanjetJPEGWriter *w)
{
    if (!w) return;
    for (int i = 0; i < JPEG_MCU; i++) free(w->line[i]);
    if (w->file) fclose(w->file);
    free(w);
}

ScanjetJPEGWriter *scanjet_jpeg_open(const char *path, uint32_t width, uint32_t height,
                                     int samples_per_pixel, uint32_t dpi, int quality)
{
    g_jpeg_error[0] = 0;
    ensure_tables();
    if (!path || width == 0 || height == 0 ||
        (samples_per_pixel != 1 && samples_per_pixel != 3)) {
        set_err("invalid JPEG parameters");
        return NULL;
    }

    ScanjetJPEGWriter *w = calloc(1, sizeof(*w));
    if (!w) {
        set_err("out of memory");
        return NULL;
    }
    w->width = width;
    w->height = height;
    w->spp = samples_per_pixel;
    w->mcu_w = samples_per_pixel == 1 ? 8 : 16;
    w->mcu_h = w->mcu_w;
    w->blocks_x = (int)((width + (uint32_t)w->mcu_w - 1) / (uint32_t)w->mcu_w);
    scale_quant(w->qy, kStdLumQuant, quality <= 0 ? 92 : quality);
    scale_quant(w->qc, kStdChrQuant, quality <= 0 ? 92 : quality);

    size_t rowb = (size_t)width * (size_t)samples_per_pixel;
    for (int i = 0; i < JPEG_MCU; i++) {
        w->line[i] = calloc(rowb, 1);
        if (!w->line[i]) {
            set_err("out of memory");
            free_writer(w);
            return NULL;
        }
    }

    w->file = fopen(path, "wb");
    if (!w->file) {
        set_err("cannot create JPEG file");
        free_writer(w);
        return NULL;
    }
    (void)fcntl(fileno(w->file), F_NOCACHE, 1);

    static const uint8_t soi[2] = { 0xff, 0xd8 };
    if (fwrite(soi, 1, 2, w->file) != 2) {
        set_err("cannot write JPEG SOI");
        free_writer(w);
        return NULL;
    }

    uint8_t app0[14] = {
        'J','F','I','F',0, 1, 2,
        dpi > 0 ? 1 : 0,
        (uint8_t)((dpi >> 8) & 0xff), (uint8_t)(dpi & 0xff),
        (uint8_t)((dpi >> 8) & 0xff), (uint8_t)(dpi & 0xff),
        0, 0
    };
    if (marker(w, 0xe0, app0, 14) != 0) { free_writer(w); return NULL; }
    if (write_dqt(w, 0, w->qy) != 0) { free_writer(w); return NULL; }
    if (samples_per_pixel == 3 && write_dqt(w, 1, w->qc) != 0) { free_writer(w); return NULL; }

    uint8_t sof[19];
    int ncomp = samples_per_pixel;
    int soflen = 6 + ncomp * 3;
    sof[0] = 8;
    sof[1] = (uint8_t)((height >> 8) & 0xff);
    sof[2] = (uint8_t)(height & 0xff);
    sof[3] = (uint8_t)((width >> 8) & 0xff);
    sof[4] = (uint8_t)(width & 0xff);
    sof[5] = (uint8_t)ncomp;
    if (ncomp == 1) {
        sof[6] = 1; sof[7] = 0x11; sof[8] = 0;
    } else {
        sof[6] = 1; sof[7] = 0x22; sof[8] = 0;
        sof[9] = 2; sof[10] = 0x11; sof[11] = 1;
        sof[12] = 3; sof[13] = 0x11; sof[14] = 1;
    }
    if (put_byte(w, 0xff) != 0 || put_byte(w, 0xc0) != 0) { free_writer(w); return NULL; }
    int seglen = soflen + 2;
    if (put_byte(w, (seglen >> 8) & 0xff) != 0 || put_byte(w, seglen & 0xff) != 0) {
        free_writer(w); return NULL;
    }
    w->sof_offset = ftell(w->file);
    if (fwrite(sof, 1, (size_t)soflen, w->file) != (size_t)soflen) {
        set_err("cannot write JPEG SOF");
        free_writer(w);
        return NULL;
    }

    if (write_dht(w, 0x00, kDcLumBits, kDcLumVal, 12) != 0) { free_writer(w); return NULL; }
    if (write_dht(w, 0x10, kAcLumBits, kAcLumVal, 162) != 0) { free_writer(w); return NULL; }
    if (ncomp == 3) {
        if (write_dht(w, 0x01, kDcChrBits, kDcChrVal, 12) != 0) { free_writer(w); return NULL; }
        if (write_dht(w, 0x11, kAcChrBits, kAcChrVal, 162) != 0) { free_writer(w); return NULL; }
    }

    uint8_t sos[12];
    sos[0] = (uint8_t)ncomp;
    if (ncomp == 1) {
        sos[1] = 1; sos[2] = 0x00;
        sos[3] = 0; sos[4] = 63; sos[5] = 0;
        if (marker(w, 0xda, sos, 6) != 0) { free_writer(w); return NULL; }
    } else {
        sos[1] = 1; sos[2] = 0x00;
        sos[3] = 2; sos[4] = 0x11;
        sos[5] = 3; sos[6] = 0x11;
        sos[7] = 0; sos[8] = 63; sos[9] = 0;
        if (marker(w, 0xda, sos, 10) != 0) { free_writer(w); return NULL; }
    }
    return w;
}

int scanjet_jpeg_write_row(ScanjetJPEGWriter *w, const uint8_t *pixels, size_t nbytes)
{
    if (!w || !pixels || nbytes != (size_t)w->width * (size_t)w->spp) {
        set_err("JPEG row size mismatch");
        return -1;
    }
    if (w->buffered >= JPEG_MCU) {
        set_err("JPEG row buffer overflow");
        return -1;
    }
    memcpy(w->line[w->buffered], pixels, nbytes);
    w->buffered++;
    w->rows++;
    if (w->buffered >= w->mcu_h) {
        if (flush_mcu_rows(w, 0) != 0) return -1;
    }
    return 0;
}

int scanjet_jpeg_close(ScanjetJPEGWriter *w)
{
    if (!w) return -1;
    int rc = 0;
    if (w->file) {
        if (w->rows == 0) {
            set_err("JPEG has no rows");
            rc = -1;
        }
        if (rc == 0 && flush_mcu_rows(w, 1) != 0) rc = -1;
        if (rc == 0 && flush_bits(w) != 0) rc = -1;
        if (rc == 0 && w->sof_offset >= 0 && w->rows != w->height && w->rows > 0) {
            long here = ftell(w->file);
            if (fseek(w->file, w->sof_offset + 1, SEEK_SET) == 0) {
                uint8_t hw[2] = { (uint8_t)((w->rows >> 8) & 0xff), (uint8_t)(w->rows & 0xff) };
                if (fwrite(hw, 1, 2, w->file) != 2) rc = -1;
            }
            if (here >= 0) fseek(w->file, here, SEEK_SET);
        }
        if (rc == 0) {
            if (put_byte(w, 0xff) != 0 || put_byte(w, 0xd9) != 0) rc = -1;
        }
        if (fclose(w->file) != 0 && rc == 0) {
            set_err("cannot close JPEG");
            rc = -1;
        }
        w->file = NULL;
    }
    for (int i = 0; i < JPEG_MCU; i++) {
        free(w->line[i]);
        w->line[i] = NULL;
    }
    free(w);
    return rc;
}
