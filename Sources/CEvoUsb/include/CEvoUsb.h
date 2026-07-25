#ifndef CEVOUSB_H
#define CEVOUSB_H

#include <stdint.h>

// Opens (once) and caches a handle to the Audient EVO device.
// Returns 0 on success. Safe to call repeatedly; subsequent calls are cheap.
int evo_usb_open(char *error, int error_length);

// Closes the cached handle and releases libusb. Safe to call when not open.
void evo_usb_close(void);

// Returns 1 if a cached, usable handle is currently held.
int evo_usb_is_open(void);

// Reports whether the vendor control endpoint is reachable.
// 0 = reachable, negative = libusb error code from the probe transfer.
int evo_usb_probe(char *error, int error_length);

int evo_usb_control_set(uint16_t w_value, uint16_t w_index, const uint8_t *data, int length, char *error, int error_length);
int evo_usb_control_get(uint16_t w_value, uint16_t w_index, uint8_t *data, int length, char *error, int error_length);

#endif
