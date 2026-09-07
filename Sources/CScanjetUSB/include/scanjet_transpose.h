#ifndef SCANJET_TRANSPOSE_H
#define SCANJET_TRANSPOSE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*scanjet_progress_cb)(double fraction, void *ctx);
typedef struct ScanjetTransposeWriter ScanjetTransposeWriter;

/// 90° CW if clockwise != 0, otherwise 270° CW. Strip buffers are packed pixels, `bpp` bytes each.
int scanjet_transpose_strip(const char *src_path, uint64_t src_off,
                            uint32_t src_w, uint32_t src_h, int bpp, int clockwise,
                            const char *dst_path, uint64_t dst_off,
                            scanjet_progress_cb progress, void *ctx);

/// Scatter source rows into a pre-sized rotated TIFF (header + strip) during decode.
ScanjetTransposeWriter *scanjet_transpose_writer_open(const char *path,
                                                      uint32_t src_w, uint32_t src_h,
                                                      int bpp, int clockwise);
int scanjet_transpose_writer_row(ScanjetTransposeWriter *writer,
                                 const uint8_t *row, size_t nbytes);
int scanjet_transpose_writer_row16(ScanjetTransposeWriter *writer,
                                   const uint16_t *samples, size_t count);
int scanjet_transpose_writer_close(ScanjetTransposeWriter *writer);

const char *scanjet_transpose_last_error(void);

#ifdef __cplusplus
}
#endif

#endif
