#ifndef SCANJET_USB_H
#define SCANJET_USB_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define SCANJET_VID 0x03f0
#define SCANJET_PID 0x1c05

typedef struct ScanjetDeviceInfo {
    uint16_t vendor_id;
    uint16_t product_id;
    uint16_t bcd_device;
    uint8_t device_class;
    uint8_t num_configurations;
    uint8_t bus;
    uint8_t address;
    char manufacturer[128];
    char product[128];
    char serial[128];
} ScanjetDeviceInfo;

typedef struct ScanjetEndpointInfo {
    uint8_t address;
    uint8_t attributes;
    uint16_t max_packet;
    uint8_t interval;
} ScanjetEndpointInfo;

int scanjet_usb_init(void);
void scanjet_usb_exit(void);

int scanjet_usb_find(ScanjetDeviceInfo *info);
const char *scanjet_usb_info_manufacturer(const ScanjetDeviceInfo *info);
const char *scanjet_usb_info_product(const ScanjetDeviceInfo *info);
const char *scanjet_usb_info_serial(const ScanjetDeviceInfo *info);
int scanjet_usb_open(void);
void scanjet_usb_close(void);
int scanjet_usb_is_open(void);
int scanjet_usb_reset(void);

int scanjet_usb_control_in(uint8_t request, uint16_t value, uint16_t index,
                           uint8_t *data, uint16_t length, int timeout_ms);
int scanjet_usb_control_out(uint8_t request, uint16_t value, uint16_t index,
                            const uint8_t *data, uint16_t length, int timeout_ms);

int scanjet_usb_bulk_in(uint8_t endpoint, uint8_t *data, int length,
                        int *transferred, int timeout_ms);
int scanjet_usb_bulk_out(uint8_t endpoint, const uint8_t *data, int length,
                         int *transferred, int timeout_ms);
int scanjet_usb_interrupt_in(uint8_t endpoint, uint8_t *data, int length,
                             int *transferred, int timeout_ms);

int scanjet_usb_list_endpoints(ScanjetEndpointInfo *out, int max_count);
const char *scanjet_usb_last_error(void);
int scanjet_usb_is_timeout(int code);

#ifdef __cplusplus
}
#endif

#endif
