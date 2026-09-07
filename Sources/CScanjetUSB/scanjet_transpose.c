#include "scanjet_transpose.h"

#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define TILE 256

struct ScanjetTransposeWriter {
    uint8_t *map;
    size_t map_len;
    uint8_t *dst;
    uint8_t *band;
    size_t src_bpr;
    uint32_t src_w;
    uint32_t src_h;
    uint32_t y;
    uint32_t fill;
    int bpp;
    int clockwise;
    int fd;
};

static char g_err[256];

const char *scanjet_transpose_last_error(void)
{
    return g_err;
}

static void set_err(const char *msg)
{
    snprintf(g_err, sizeof(g_err), "%s", msg);
}

static void scatter_band(const uint8_t *band, uint32_t th, uint32_t y0,
                         uint32_t src_w, uint32_t src_h, int bpp, int clockwise,
                         uint8_t *dst)
{
    size_t src_bpr = (size_t)src_w * (size_t)bpp;
    size_t out_bpr = (size_t)src_h * (size_t)bpp;
    uint8_t tmp[TILE * 8];

    for (uint32_t x = 0; x < src_w; x++) {
        if (clockwise) {
            uint8_t *d = dst + (size_t)x * out_bpr + (size_t)(src_h - y0 - th) * (size_t)bpp;
            for (uint32_t r = 0; r < th; r++) {
                memcpy(tmp + (size_t)r * (size_t)bpp,
                       band + (size_t)(th - 1 - r) * src_bpr + (size_t)x * (size_t)bpp,
                       (size_t)bpp);
            }
            memcpy(d, tmp, (size_t)th * (size_t)bpp);
        } else {
            uint8_t *d = dst + (size_t)(src_w - 1 - x) * out_bpr + (size_t)y0 * (size_t)bpp;
            for (uint32_t r = 0; r < th; r++) {
                memcpy(tmp + (size_t)r * (size_t)bpp,
                       band + (size_t)r * src_bpr + (size_t)x * (size_t)bpp,
                       (size_t)bpp);
            }
            memcpy(d, tmp, (size_t)th * (size_t)bpp);
        }
    }
}

static int flush_writer_band(ScanjetTransposeWriter *writer)
{
    if (writer->fill == 0) return 0;
    uint32_t y0 = writer->y - writer->fill;
    scatter_band(writer->band, writer->fill, y0, writer->src_w, writer->src_h,
                 writer->bpp, writer->clockwise, writer->dst);
    writer->fill = 0;
    return 0;
}

int scanjet_transpose_strip(const char *src_path, uint64_t src_off,
                            uint32_t src_w, uint32_t src_h, int bpp, int clockwise,
                            const char *dst_path, uint64_t dst_off,
                            scanjet_progress_cb progress, void *ctx)
{
    g_err[0] = 0;
    if (!src_path || !dst_path || src_w == 0 || src_h == 0 || bpp < 1 || bpp > 8) {
        set_err("invalid transpose parameters");
        return -1;
    }

    int src_fd = open(src_path, O_RDONLY);
    if (src_fd < 0) {
        set_err("cannot open source for rotate");
        return -1;
    }
    (void)fcntl(src_fd, F_NOCACHE, 1);

    int dst_fd = open(dst_path, O_RDWR);
    if (dst_fd < 0) {
        set_err("cannot open destination for rotate");
        close(src_fd);
        return -1;
    }
    (void)fcntl(dst_fd, F_NOCACHE, 1);

    size_t src_bpr = (size_t)src_w * (size_t)bpp;
    size_t out_bpr = (size_t)src_h * (size_t)bpp;
    size_t dst_bytes = dst_off + (size_t)src_w * out_bpr;
    uint8_t *band = malloc(TILE * src_bpr);
    if (!band) {
        set_err("out of memory");
        close(src_fd);
        close(dst_fd);
        return -1;
    }

    uint8_t *map = mmap(NULL, dst_bytes, PROT_READ | PROT_WRITE, MAP_SHARED, dst_fd, 0);
    if (map == MAP_FAILED) {
        set_err("cannot map rotated strip");
        free(band);
        close(src_fd);
        close(dst_fd);
        return -1;
    }
    uint8_t *dst = map + dst_off;

    int rc = 0;
    for (uint32_t y0 = 0; y0 < src_h; y0 += TILE) {
        uint32_t th = src_h - y0;
        if (th > TILE) th = TILE;
        ssize_t want = (ssize_t)th * (ssize_t)src_bpr;
        ssize_t got = pread(src_fd, band, (size_t)want, (off_t)(src_off + (uint64_t)y0 * src_bpr));
        if (got != want) {
            set_err("short read while rotating");
            rc = -1;
            break;
        }
        scatter_band(band, th, y0, src_w, src_h, bpp, clockwise, dst);
        if (progress) {
            progress((double)(y0 + th) / (double)src_h, ctx);
        }
    }

    msync(map, dst_bytes, MS_SYNC);
    munmap(map, dst_bytes);
    free(band);
    close(src_fd);
    close(dst_fd);
    return rc;
}

ScanjetTransposeWriter *scanjet_transpose_writer_open(const char *path,
                                                      uint32_t src_w, uint32_t src_h,
                                                      int bpp, int clockwise)
{
    g_err[0] = 0;
    if (!path || src_w == 0 || src_h == 0 || bpp < 1 || bpp > 8) {
        set_err("invalid transpose parameters");
        return NULL;
    }

    ScanjetTransposeWriter *writer = calloc(1, sizeof(*writer));
    if (!writer) {
        set_err("out of memory");
        return NULL;
    }
    writer->src_w = src_w;
    writer->src_h = src_h;
    writer->bpp = bpp;
    writer->clockwise = clockwise;
    writer->src_bpr = (size_t)src_w * (size_t)bpp;
    writer->map_len = 8 + (size_t)src_w * (size_t)src_h * (size_t)bpp;
    writer->band = malloc(TILE * writer->src_bpr);
    if (!writer->band) {
        set_err("out of memory");
        free(writer);
        return NULL;
    }

    writer->fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (writer->fd < 0) {
        set_err("cannot create rotated TIFF");
        free(writer->band);
        free(writer);
        return NULL;
    }
    (void)fcntl(writer->fd, F_NOCACHE, 1);

    static const uint8_t header[8] = { 0x49, 0x49, 42, 0, 0, 0, 0, 0 };
    if (write(writer->fd, header, 8) != 8 || ftruncate(writer->fd, (off_t)writer->map_len) != 0) {
        set_err("cannot size rotated TIFF");
        close(writer->fd);
        free(writer->band);
        free(writer);
        return NULL;
    }

    writer->map = mmap(NULL, writer->map_len, PROT_READ | PROT_WRITE, MAP_SHARED, writer->fd, 0);
    if (writer->map == MAP_FAILED) {
        set_err("cannot map rotated strip");
        close(writer->fd);
        free(writer->band);
        free(writer);
        return NULL;
    }
    writer->dst = writer->map + 8;
    return writer;
}

int scanjet_transpose_writer_row(ScanjetTransposeWriter *writer,
                                 const uint8_t *row, size_t nbytes)
{
    if (!writer || !row || nbytes != writer->src_bpr) {
        set_err("transpose row size mismatch");
        return -1;
    }
    if (writer->y >= writer->src_h) {
        set_err("transpose wrote past expected height");
        return -1;
    }
    memcpy(writer->band + (size_t)writer->fill * writer->src_bpr, row, nbytes);
    writer->fill += 1;
    writer->y += 1;
    if (writer->fill == TILE || writer->y == writer->src_h) {
        return flush_writer_band(writer);
    }
    return 0;
}

int scanjet_transpose_writer_row16(ScanjetTransposeWriter *writer,
                                   const uint16_t *samples, size_t count)
{
    if (!writer || !samples) {
        set_err("transpose row size mismatch");
        return -1;
    }
    return scanjet_transpose_writer_row(writer, (const uint8_t *)samples, count * 2);
}

int scanjet_transpose_writer_close(ScanjetTransposeWriter *writer)
{
    if (!writer) return -1;
    int rc = flush_writer_band(writer);
    if (writer->map && writer->map != MAP_FAILED) {
        if (msync(writer->map, writer->map_len, MS_SYNC) != 0 && rc == 0) {
            set_err("cannot sync rotated TIFF");
            rc = -1;
        }
        munmap(writer->map, writer->map_len);
        writer->map = NULL;
    }
    if (writer->fd >= 0) {
        close(writer->fd);
        writer->fd = -1;
    }
    free(writer->band);
    free(writer);
    return rc;
}
