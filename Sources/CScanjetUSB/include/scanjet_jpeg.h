#ifndef SCANJET_JPEG_H
#define SCANJET_JPEG_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ScanjetJPEGWriter ScanjetJPEGWriter;

ScanjetJPEGWriter *scanjet_jpeg_open(const char *path, uint32_t width, uint32_t height,
                                     int samples_per_pixel, uint32_t dpi, int quality);
int scanjet_jpeg_write_row(ScanjetJPEGWriter *writer, const uint8_t *pixels, size_t nbytes);
int scanjet_jpeg_close(ScanjetJPEGWriter *writer);
const char *scanjet_jpeg_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
