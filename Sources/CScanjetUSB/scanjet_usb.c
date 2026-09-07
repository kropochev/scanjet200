#include "scanjet_usb.h"

#include <libusb.h>
#include <stdio.h>
#include <string.h>

static libusb_context *g_ctx = NULL;
static libusb_device_handle *g_handle = NULL;
static char g_error[512] = {0};

static void set_error(const char *fmt, int code)
{
    if (code != 0) {
        snprintf(g_error, sizeof(g_error), "%s: %s (%d)", fmt, libusb_strerror(code), code);
    } else {
        snprintf(g_error, sizeof(g_error), "%s", fmt);
    }
}

const char *scanjet_usb_last_error(void)
{
    return g_error;
}

int scanjet_usb_is_timeout(int code)
{
    return code == LIBUSB_ERROR_TIMEOUT;
}

int scanjet_usb_init(void)
{
    if (g_ctx) {
        return 0;
    }
    int rc = libusb_init(&g_ctx);
    if (rc != 0) {
        set_error("libusb_init", rc);
        g_ctx = NULL;
        return rc;
    }
    libusb_set_option(g_ctx, LIBUSB_OPTION_LOG_LEVEL, LIBUSB_LOG_LEVEL_WARNING);
    return 0;
}

void scanjet_usb_exit(void)
{
    scanjet_usb_close();
    if (g_ctx) {
        libusb_exit(g_ctx);
        g_ctx = NULL;
    }
}

static void fill_string(libusb_device_handle *handle, uint8_t index, char *dst, size_t dst_len)
{
    memset(dst, 0, dst_len);
    if (handle == NULL || index == 0) {
        return;
    }
    libusb_get_string_descriptor_ascii(handle, index, (unsigned char *)dst, (int)dst_len - 1);
}

int scanjet_usb_find(ScanjetDeviceInfo *info)
{
    if (!g_ctx) {
        int rc = scanjet_usb_init();
        if (rc != 0) {
            return rc;
        }
    }
    if (info == NULL) {
        set_error("info is NULL", 0);
        return -1;
    }
    memset(info, 0, sizeof(*info));

    libusb_device **list = NULL;
    ssize_t count = libusb_get_device_list(g_ctx, &list);
    if (count < 0) {
        set_error("libusb_get_device_list", (int)count);
        return (int)count;
    }

    int found = -1;
    for (ssize_t i = 0; i < count; i++) {
        struct libusb_device_descriptor desc;
        int rc = libusb_get_device_descriptor(list[i], &desc);
        if (rc != 0) {
            continue;
        }
        if (desc.idVendor != SCANJET_VID || desc.idProduct != SCANJET_PID) {
            continue;
        }

        info->vendor_id = desc.idVendor;
        info->product_id = desc.idProduct;
        info->bcd_device = desc.bcdDevice;
        info->device_class = desc.bDeviceClass;
        info->num_configurations = desc.bNumConfigurations;
        info->bus = libusb_get_bus_number(list[i]);
        info->address = libusb_get_device_address(list[i]);

        libusb_device_handle *tmp = NULL;
        if (libusb_open(list[i], &tmp) == 0) {
            fill_string(tmp, desc.iManufacturer, info->manufacturer, sizeof(info->manufacturer));
            fill_string(tmp, desc.iProduct, info->product, sizeof(info->product));
            fill_string(tmp, desc.iSerialNumber, info->serial, sizeof(info->serial));
            libusb_close(tmp);
        }
        found = 0;
        break;
    }

    libusb_free_device_list(list, 1);
    if (found != 0) {
        set_error("HP Scanjet 200 not found (03f0:1c05)", 0);
    }
    return found;
}

const char *scanjet_usb_info_manufacturer(const ScanjetDeviceInfo *info)
{
    return info ? info->manufacturer : "";
}

const char *scanjet_usb_info_product(const ScanjetDeviceInfo *info)
{
    return info ? info->product : "";
}

const char *scanjet_usb_info_serial(const ScanjetDeviceInfo *info)
{
    return info ? info->serial : "";
}

int scanjet_usb_open(void)
{
    if (g_handle) {
        return 0;
    }
    if (!g_ctx) {
        int rc = scanjet_usb_init();
        if (rc != 0) {
            return rc;
        }
    }

    g_handle = libusb_open_device_with_vid_pid(g_ctx, SCANJET_VID, SCANJET_PID);
    if (!g_handle) {
        set_error("cannot open HP Scanjet 200", 0);
        return -1;
    }

    libusb_set_auto_detach_kernel_driver(g_handle, 1);

    int cfg = 0;
    int rc = libusb_get_configuration(g_handle, &cfg);
    if (rc == 0 && cfg != 1) {
        rc = libusb_set_configuration(g_handle, 1);
        if (rc != 0 && rc != LIBUSB_ERROR_BUSY) {
            set_error("libusb_set_configuration", rc);
            libusb_close(g_handle);
            g_handle = NULL;
            return rc;
        }
    }

    rc = libusb_claim_interface(g_handle, 0);
    if (rc != 0) {
        set_error("libusb_claim_interface", rc);
        libusb_close(g_handle);
        g_handle = NULL;
        return rc;
    }
    return 0;
}

void scanjet_usb_close(void)
{
    if (!g_handle) {
        return;
    }
    libusb_release_interface(g_handle, 0);
    libusb_close(g_handle);
    g_handle = NULL;
}

int scanjet_usb_is_open(void)
{
    return g_handle != NULL;
}

int scanjet_usb_reset(void)
{
    if (!g_handle) {
        set_error("device not open", 0);
        return -1;
    }
    int rc = libusb_reset_device(g_handle);
    if (rc != 0 && rc != LIBUSB_ERROR_NOT_FOUND) {
        set_error("libusb_reset_device", rc);
        return rc;
    }
    // After reset the handle may still be valid; reclaim interface.
    libusb_set_auto_detach_kernel_driver(g_handle, 1);
    (void)libusb_set_configuration(g_handle, 1);
    rc = libusb_claim_interface(g_handle, 0);
    if (rc != 0) {
        set_error("claim after reset", rc);
        return rc;
    }
    return 0;
}

int scanjet_usb_control_in(uint8_t request, uint16_t value, uint16_t index,
                           uint8_t *data, uint16_t length, int timeout_ms)
{
    if (!g_handle) {
        set_error("device not open", 0);
        return -1;
    }
    int rc = libusb_control_transfer(
        g_handle,
        LIBUSB_ENDPOINT_IN | LIBUSB_REQUEST_TYPE_VENDOR | LIBUSB_RECIPIENT_DEVICE,
        request, value, index, data, length, timeout_ms);
    if (rc < 0) {
        set_error("control IN", rc);
        return rc;
    }
    return rc;
}

int scanjet_usb_control_out(uint8_t request, uint16_t value, uint16_t index,
                            const uint8_t *data, uint16_t length, int timeout_ms)
{
    if (!g_handle) {
        set_error("device not open", 0);
        return -1;
    }
    int rc = libusb_control_transfer(
        g_handle,
        LIBUSB_ENDPOINT_OUT | LIBUSB_REQUEST_TYPE_VENDOR | LIBUSB_RECIPIENT_DEVICE,
        request, value, index, (uint8_t *)data, length, timeout_ms);
    if (rc < 0) {
        set_error("control OUT", rc);
        return rc;
    }
    return rc;
}

int scanjet_usb_bulk_in(uint8_t endpoint, uint8_t *data, int length,
                        int *transferred, int timeout_ms)
{
    if (!g_handle) {
        set_error("device not open", 0);
        return -1;
    }
    int n = 0;
    int rc = libusb_bulk_transfer(g_handle, endpoint, data, length, &n, timeout_ms);
    if (transferred) {
        *transferred = n;
    }
    if (rc != 0) {
        set_error("bulk IN", rc);
    }
    return rc;
}

int scanjet_usb_bulk_out(uint8_t endpoint, const uint8_t *data, int length,
                         int *transferred, int timeout_ms)
{
    if (!g_handle) {
        set_error("device not open", 0);
        return -1;
    }
    int n = 0;
    int rc = libusb_bulk_transfer(g_handle, endpoint, (uint8_t *)data, length, &n, timeout_ms);
    if (transferred) {
        *transferred = n;
    }
    if (rc != 0) {
        set_error("bulk OUT", rc);
    }
    return rc;
}

int scanjet_usb_interrupt_in(uint8_t endpoint, uint8_t *data, int length,
                             int *transferred, int timeout_ms)
{
    if (!g_handle) {
        set_error("device not open", 0);
        return -1;
    }
    int n = 0;
    int rc = libusb_interrupt_transfer(g_handle, endpoint, data, length, &n, timeout_ms);
    if (transferred) {
        *transferred = n;
    }
    if (rc != 0 && rc != LIBUSB_ERROR_TIMEOUT) {
        set_error("interrupt IN", rc);
    }
    return rc;
}

int scanjet_usb_list_endpoints(ScanjetEndpointInfo *out, int max_count)
{
    if (!g_handle || !out || max_count <= 0) {
        set_error("device not open", 0);
        return -1;
    }
    libusb_device *dev = libusb_get_device(g_handle);
    struct libusb_config_descriptor *cfg = NULL;
    int rc = libusb_get_active_config_descriptor(dev, &cfg);
    if (rc != 0) {
        set_error("libusb_get_active_config_descriptor", rc);
        return rc;
    }
    int n = 0;
    for (int i = 0; i < cfg->bNumInterfaces && n < max_count; i++) {
        const struct libusb_interface *iface = &cfg->interface[i];
        for (int a = 0; a < iface->num_altsetting && n < max_count; a++) {
            const struct libusb_interface_descriptor *alt = &iface->altsetting[a];
            for (int e = 0; e < alt->bNumEndpoints && n < max_count; e++) {
                const struct libusb_endpoint_descriptor *ep = &alt->endpoint[e];
                out[n].address = ep->bEndpointAddress;
                out[n].attributes = ep->bmAttributes;
                out[n].max_packet = ep->wMaxPacketSize;
                out[n].interval = ep->bInterval;
                n++;
            }
        }
    }
    libusb_free_config_descriptor(cfg);
    return n;
}
