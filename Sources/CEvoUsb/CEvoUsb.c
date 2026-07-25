#include "CEvoUsb.h"

#include <libusb.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

// The EVO control protocol (matching the known Linux implementations):
//   bmRequestType 0x21 (SET), bRequest 0x01
//   wIndex 0x3A00 = input block (phantom, gain), 0x3B00 = output, 0x3C00 = monitor mix
//
// The device is WRITE-ONLY for these vendor controls. The reference
// implementations (evoctl, audient-evo-linux-tools) never issue a 0xA1 GET;
// evoctl's README states outright that "no parameters are read back from the
// device". A 0xA1 read returns LIBUSB_ERROR_IO even with interface 0 claimed,
// so device state cannot be queried -- it must be tracked locally.
//
// Interface 0 must be claimed before the vendor control endpoint responds.
#define EVO_CONTROL_INTERFACE 0

static libusb_device_handle *g_handle = NULL;
static int g_claimed_interface = -1;
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

static void write_error(char *error, int error_length, const char *message) {
    if (error == NULL || error_length <= 0) {
        return;
    }
    snprintf(error, (size_t)error_length, "%s", message);
}

static libusb_device_handle *open_evo_device(void) {
    const uint16_t vendor_id = 0x2708;
    const uint16_t products[] = {0x0006, 0x0007, 0x0008, 0x000a};

    for (int index = 0; index < 4; index++) {
        libusb_device_handle *handle = libusb_open_device_with_vid_pid(NULL, vendor_id, products[index]);
        if (handle != NULL) {
            return handle;
        }
    }
    return NULL;
}

// Must hold g_lock.
static int ensure_open_locked(char *error, int error_length) {
    if (g_handle != NULL) {
        return 0;
    }

    int status = libusb_init_context(NULL, NULL, 0);
    if (status != LIBUSB_SUCCESS) {
        write_error(error, error_length, libusb_error_name(status));
        return status;
    }

    libusb_device_handle *handle = open_evo_device();
    if (handle == NULL) {
        libusb_exit(NULL);
        write_error(error, error_length, "Audient EVO USB device was not found.");
        return LIBUSB_ERROR_NO_DEVICE;
    }

    // Deliberately do NOT detach the macOS USB-audio class driver or claim an
    // interface. SET transfers (bmRequestType 0x21) to the vendor control
    // endpoint work fine alongside the class driver, and this is how the
    // original working implementation behaved. Detaching under root strips the
    // device out of CoreAudio entirely, so it must not happen here.
    g_handle = handle;
    g_claimed_interface = -1;
    return 0;
}

int evo_usb_open(char *error, int error_length) {
    pthread_mutex_lock(&g_lock);
    int result = ensure_open_locked(error, error_length);
    pthread_mutex_unlock(&g_lock);
    return result;
}

void evo_usb_close(void) {
    pthread_mutex_lock(&g_lock);
    if (g_handle != NULL) {
        libusb_close(g_handle);
        libusb_exit(NULL);
        g_handle = NULL;
    }
    pthread_mutex_unlock(&g_lock);
}

int evo_usb_is_open(void) {
    pthread_mutex_lock(&g_lock);
    int open = g_handle != NULL;
    pthread_mutex_unlock(&g_lock);
    return open;
}

int evo_usb_probe(char *error, int error_length) {
    pthread_mutex_lock(&g_lock);
    int status = ensure_open_locked(error, error_length);
    if (g_handle == NULL) {
        pthread_mutex_unlock(&g_lock);
        return status != 0 ? status : LIBUSB_ERROR_NO_DEVICE;
    }

    // Availability means "the device is open". Writes are not probed: a 0xA1
    // read is unsupported by the hardware and a 0x21 write would change device
    // state, so neither is a safe health check. Individual SET calls report
    // their own success or failure.
    pthread_mutex_unlock(&g_lock);
    return 0;
}

int evo_usb_control_set(uint16_t w_value, uint16_t w_index, const uint8_t *data, int length, char *error, int error_length) {
    pthread_mutex_lock(&g_lock);
    int status = ensure_open_locked(error, error_length);
    if (g_handle == NULL) {
        pthread_mutex_unlock(&g_lock);
        return status != 0 ? status : LIBUSB_ERROR_NO_DEVICE;
    }

    unsigned char buffer[4] = {0, 0, 0, 0};
    if (length > 4) {
        length = 4;
    }
    memcpy(buffer, data, (size_t)length);

    int transferred = libusb_control_transfer(
        g_handle,
        0x21,
        0x01,
        w_value,
        w_index,
        buffer,
        (uint16_t)length,
        1000
    );
    pthread_mutex_unlock(&g_lock);

    if (transferred < 0) {
        write_error(error, error_length, libusb_error_name(transferred));
        return transferred;
    }
    if (transferred != length) {
        write_error(error, error_length, "EVO USB command wrote fewer bytes than expected.");
        return LIBUSB_ERROR_IO;
    }

    return LIBUSB_SUCCESS;
}

int evo_usb_control_get(uint16_t w_value, uint16_t w_index, uint8_t *data, int length, char *error, int error_length) {
    pthread_mutex_lock(&g_lock);
    int status = ensure_open_locked(error, error_length);
    if (g_handle == NULL) {
        pthread_mutex_unlock(&g_lock);
        return status != 0 ? status : LIBUSB_ERROR_NO_DEVICE;
    }

    if (length > 4) {
        length = 4;
    }
    memset(data, 0, (size_t)length);

    int transferred = libusb_control_transfer(
        g_handle,
        0xA1,
        0x01,
        w_value,
        w_index,
        data,
        (uint16_t)length,
        100
    );
    pthread_mutex_unlock(&g_lock);

    if (transferred < 0) {
        if (error != NULL && error_length > 0) {
            snprintf(
                error,
                (size_t)error_length,
                "%s get wValue=0x%04x wIndex=0x%04x len=%d",
                libusb_error_name(transferred),
                w_value,
                w_index,
                length
            );
        }
        return transferred;
    }
    if (transferred != length) {
        if (transferred > 0) {
            return LIBUSB_SUCCESS;
        }
        if (error != NULL && error_length > 0) {
            snprintf(
                error,
                (size_t)error_length,
                "EVO USB command read zero bytes wValue=0x%04x wIndex=0x%04x len=%d",
                w_value,
                w_index,
                length
            );
        }
        return LIBUSB_ERROR_IO;
    }

    return LIBUSB_SUCCESS;
}
