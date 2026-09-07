#ifndef SCANJET_PNG_H
#define SCANJET_PNG_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ScanjetPNGWriter ScanjetPNGWriter;

typedef void (*scanjet_png_progress_cb)(double fraction, void *ctx);

ScanjetPNGWriter *scanjet_png_open(const char *path, uint32_t width, uint32_t height,
                                   int samples_per_pixel, int bits_per_sample, uint32_t pixels_per_metre);
int scanjet_png_write_row(ScanjetPNGWriter *writer, const uint8_t *pixels, size_t nbytes);
int scanjet_png_write_strip(ScanjetPNGWriter *writer, const char *path, uint64_t offset,
                            uint32_t height, uint32_t bytes_per_row,
                            scanjet_png_progress_cb progress, void *ctx);
int scanjet_png_close(ScanjetPNGWriter *writer);
const char *scanjet_png_last_error(void);

void scanjet_release_memory(void);

#ifdef __cplusplus
}
#endif

#endif
