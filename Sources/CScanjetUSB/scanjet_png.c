#include "scanjet_png.h"

#include <fcntl.h>
#include <malloc/malloc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <zlib.h>

#define PNG_OUT_BUF (1024 * 1024)
#define PNG_BATCH_ROWS 16

struct ScanjetPNGWriter {
    FILE *file;
    z_stream strm;
    uint8_t *batch;
    uint8_t *out;
    size_t row_cap;
    size_t batch_cap;
    size_t batch_used;
    uint32_t width;
    uint32_t rows;
    int spp;
    int bps;
    int started;
};

static char g_png_error[256];

static void set_png_error(const char *msg)
{
    snprintf(g_png_error, sizeof(g_png_error), "%s", msg);
}

const char *scanjet_png_last_error(void)
{
    return g_png_error;
}

void scanjet_release_memory(void)
{
    malloc_zone_pressure_relief(NULL, 0);
}

static void put_be32(uint8_t *dst, uint32_t v)
{
    dst[0] = (uint8_t)(v >> 24);
    dst[1] = (uint8_t)(v >> 16);
    dst[2] = (uint8_t)(v >> 8);
    dst[3] = (uint8_t)v;
}

static int write_chunk(FILE *file, const char type[4], const uint8_t *data, uint32_t len)
{
    uint8_t be[4];
    put_be32(be, len);
    if (fwrite(be, 1, 4, file) != 4) return -1;
    if (fwrite(type, 1, 4, file) != 4) return -1;
    if (len > 0 && fwrite(data, 1, len, file) != len) return -1;
    uLong crc = crc32(0L, Z_NULL, 0);
    crc = crc32(crc, (const Bytef *)type, 4);
    if (len > 0) {
        crc = crc32(crc, data, len);
    }
    put_be32(be, (uint32_t)crc);
    if (fwrite(be, 1, 4, file) != 4) return -1;
    return 0;
}

static int flush_deflate(ScanjetPNGWriter *writer, int flush)
{
    int ret;
    do {
        writer->strm.next_out = writer->out;
        writer->strm.avail_out = PNG_OUT_BUF;
        ret = deflate(&writer->strm, flush);
        if (ret == Z_STREAM_ERROR) {
            set_png_error("zlib deflate failed");
            return -1;
        }
        size_t have = PNG_OUT_BUF - writer->strm.avail_out;
        if (have > 0 && write_chunk(writer->file, "IDAT", writer->out, (uint32_t)have) != 0) {
            set_png_error("cannot write PNG IDAT");
            return -1;
        }
    } while (writer->strm.avail_out == 0);
    if (flush == Z_FINISH && ret != Z_STREAM_END) {
        set_png_error("zlib did not finish");
        return -1;
    }
    return 0;
}

static int patch_ihdr_height(ScanjetPNGWriter *writer)
{
    uint8_t ihdr[13];
    uint8_t crcbuf[4];
    uLong crc;

    if (!writer->file) return -1;
    put_be32(ihdr, writer->width);
    put_be32(ihdr + 4, writer->rows);
    ihdr[8] = (uint8_t)writer->bps;
    ihdr[9] = writer->spp == 3 ? 2 : 0;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    if (fseek(writer->file, 16, SEEK_SET) != 0) return -1;
    if (fwrite(ihdr, 1, 13, writer->file) != 13) return -1;
    crc = crc32(0L, Z_NULL, 0);
    crc = crc32(crc, (const Bytef *)"IHDR", 4);
    crc = crc32(crc, ihdr, 13);
    put_be32(crcbuf, (uint32_t)crc);
    if (fwrite(crcbuf, 1, 4, writer->file) != 4) return -1;
    if (fseek(writer->file, 0, SEEK_END) != 0) return -1;
    return 0;
}

ScanjetPNGWriter *scanjet_png_open(const char *path, uint32_t width, uint32_t height,
                                   int samples_per_pixel, int bits_per_sample, uint32_t pixels_per_metre)
{
    g_png_error[0] = 0;
    if (!path || width == 0 ||
        (samples_per_pixel != 1 && samples_per_pixel != 3) ||
        (bits_per_sample != 8 && bits_per_sample != 16)) {
        set_png_error("invalid PNG parameters");
        return NULL;
    }

    ScanjetPNGWriter *writer = calloc(1, sizeof(*writer));
    if (!writer) {
        set_png_error("out of memory");
        return NULL;
    }
    writer->width = width;
    writer->spp = samples_per_pixel;
    writer->bps = bits_per_sample;
    writer->row_cap = 1 + (size_t)width * (size_t)samples_per_pixel * (size_t)(bits_per_sample / 8);
    writer->batch_cap = writer->row_cap * PNG_BATCH_ROWS;
    writer->batch = malloc(writer->batch_cap);
    writer->out = malloc(PNG_OUT_BUF);
    if (!writer->batch || !writer->out) {
        set_png_error("out of memory");
        free(writer->batch);
        free(writer->out);
        free(writer);
        return NULL;
    }

    writer->file = fopen(path, "wb");
    if (!writer->file) {
        set_png_error("cannot create PNG file");
        free(writer->batch);
        free(writer->out);
        free(writer);
        return NULL;
    }
    (void)fcntl(fileno(writer->file), F_NOCACHE, 1);
    (void)setvbuf(writer->file, NULL, _IOFBF, PNG_OUT_BUF);

    static const uint8_t sig[8] = { 0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A };
    if (fwrite(sig, 1, 8, writer->file) != 8) {
        set_png_error("cannot write PNG signature");
        fclose(writer->file);
        free(writer->batch);
        free(writer->out);
        free(writer);
        return NULL;
    }

    uint8_t ihdr[13];
    put_be32(ihdr, width);
    put_be32(ihdr + 4, height);
    ihdr[8] = (uint8_t)bits_per_sample;
    ihdr[9] = samples_per_pixel == 3 ? 2 : 0;
    ihdr[10] = 0;
    ihdr[11] = 0;
    ihdr[12] = 0;
    if (write_chunk(writer->file, "IHDR", ihdr, 13) != 0) {
        set_png_error("cannot write PNG IHDR");
        fclose(writer->file);
        free(writer->batch);
        free(writer->out);
        free(writer);
        return NULL;
    }

    if (pixels_per_metre > 0) {
        uint8_t phys[9];
        put_be32(phys, pixels_per_metre);
        put_be32(phys + 4, pixels_per_metre);
        phys[8] = 1;
        if (write_chunk(writer->file, "pHYs", phys, 9) != 0) {
            set_png_error("cannot write PNG pHYs");
            fclose(writer->file);
            free(writer->batch);
            free(writer->out);
            free(writer);
            return NULL;
        }
    }

    writer->strm.zalloc = Z_NULL;
    writer->strm.zfree = Z_NULL;
    writer->strm.opaque = Z_NULL;
    if (deflateInit2(&writer->strm, Z_BEST_SPEED, Z_DEFLATED, 15, 9, Z_DEFAULT_STRATEGY) != Z_OK) {
        set_png_error("zlib init failed");
        fclose(writer->file);
        free(writer->batch);
        free(writer->out);
        free(writer);
        return NULL;
    }
    writer->started = 1;
    return writer;
}

static int flush_batch(ScanjetPNGWriter *writer)
{
    if (writer->batch_used == 0) return 0;
    writer->strm.next_in = writer->batch;
    writer->strm.avail_in = (uInt)writer->batch_used;
    while (writer->strm.avail_in > 0) {
        if (flush_deflate(writer, Z_NO_FLUSH) != 0) return -1;
    }
    writer->batch_used = 0;
    return 0;
}

int scanjet_png_write_row(ScanjetPNGWriter *writer, const uint8_t *pixels, size_t nbytes)
{
    if (!writer || !pixels || nbytes + 1 != writer->row_cap) {
        set_png_error("PNG row size mismatch");
        return -1;
    }
    if (writer->batch_used + writer->row_cap > writer->batch_cap) {
        if (flush_batch(writer) != 0) return -1;
    }
    uint8_t *dst = writer->batch + writer->batch_used;
    dst[0] = 0;
    if (writer->bps == 16) {
        const uint16_t *src = (const uint16_t *)(const void *)pixels;
        uint16_t *be = (uint16_t *)(void *)(dst + 1);
        size_t n = nbytes / 2;
        for (size_t i = 0; i < n; i++) {
            be[i] = (uint16_t)((src[i] << 8) | (src[i] >> 8));
        }
    } else {
        memcpy(dst + 1, pixels, nbytes);
    }
    writer->batch_used += writer->row_cap;
    writer->rows += 1;
    if (writer->batch_used >= writer->batch_cap) {
        return flush_batch(writer);
    }
    return 0;
}

int scanjet_png_write_strip(ScanjetPNGWriter *writer, const char *path, uint64_t offset,
                            uint32_t height, uint32_t bytes_per_row,
                            scanjet_png_progress_cb progress, void *ctx)
{
    if (!writer || !path || height == 0 || bytes_per_row == 0) {
        set_png_error("invalid PNG strip");
        return -1;
    }

    int fd = open(path, O_RDONLY);
    if (fd < 0) {
        set_png_error("cannot open PNG source");
        return -1;
    }
    (void)fcntl(fd, F_NOCACHE, 1);

    size_t chunk_rows = PNG_BATCH_ROWS;
    uint8_t *buf = malloc(chunk_rows * (size_t)bytes_per_row);
    if (!buf) {
        set_png_error("out of memory");
        close(fd);
        return -1;
    }

    int rc = 0;
    for (uint32_t y = 0; y < height; ) {
        uint32_t th = height - y;
        if (th > chunk_rows) th = (uint32_t)chunk_rows;
        size_t want = (size_t)th * (size_t)bytes_per_row;
        ssize_t got = pread(fd, buf, want, (off_t)(offset + (uint64_t)y * bytes_per_row));
        if (got != (ssize_t)want) {
            set_png_error("PNG source TIFF ended early");
            rc = -1;
            break;
        }
        for (uint32_t r = 0; r < th; r++) {
            if (scanjet_png_write_row(writer, buf + (size_t)r * bytes_per_row, bytes_per_row) != 0) {
                rc = -1;
                break;
            }
        }
        if (rc != 0) break;
        y += th;
        if (progress) {
            progress((double)y / (double)height, ctx);
        }
    }
    free(buf);
    close(fd);
    return rc;
}

int scanjet_png_close(ScanjetPNGWriter *writer)
{
    if (!writer) return -1;
    int rc = 0;
    if (writer->started) {
        if (flush_batch(writer) != 0) rc = -1;
        writer->strm.avail_in = 0;
        writer->strm.next_in = Z_NULL;
        if (rc == 0 && flush_deflate(writer, Z_FINISH) != 0) rc = -1;
        deflateEnd(&writer->strm);
        writer->started = 0;
    }
    if (rc == 0 && writer->file && writer->rows == 0) {
        set_png_error("PNG has no rows");
        rc = -1;
    }
    if (rc == 0 && writer->file && patch_ihdr_height(writer) != 0) {
        set_png_error("cannot patch PNG height");
        rc = -1;
    }
    if (rc == 0 && writer->file && write_chunk(writer->file, "IEND", NULL, 0) != 0) {
        set_png_error("cannot write PNG IEND");
        rc = -1;
    }
    if (writer->file) {
        if (fclose(writer->file) != 0 && rc == 0) {
            set_png_error("cannot close PNG file");
            rc = -1;
        }
        writer->file = NULL;
    }
    free(writer->batch);
    free(writer->out);
    free(writer);
    return rc;
}
