#include <libusb.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static volatile sig_atomic_t keep_running = 1;

static void stop_running(int signal_number) {
    (void)signal_number;
    keep_running = 0;
}

static long now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (long)(ts.tv_sec * 1000 + ts.tv_nsec / 1000000);
}

static libusb_device_handle *open_evo(uint16_t *product_id) {
    const uint16_t products[] = {0x0006, 0x0007, 0x0008, 0x000a};
    for (size_t index = 0; index < sizeof(products) / sizeof(products[0]); index++) {
        libusb_device_handle *handle = libusb_open_device_with_vid_pid(NULL, 0x2708, products[index]);
        if (handle != NULL) {
            *product_id = products[index];
            return handle;
        }
    }
    return NULL;
}

static void print_bytes(const unsigned char *data, int length) {
    for (int index = 0; index < length; index++) {
        printf("%02x%s", data[index], index + 1 == length ? "" : " ");
    }
}

static void print_descriptors(libusb_device_handle *handle) {
    libusb_device *device = libusb_get_device(handle);
    struct libusb_device_descriptor descriptor;
    int status = libusb_get_device_descriptor(device, &descriptor);
    if (status != LIBUSB_SUCCESS) {
        fprintf(stderr, "descriptor read failed: %s\n", libusb_error_name(status));
        return;
    }

    printf("device vid=%04x pid=%04x configurations=%u\n",
           descriptor.idVendor, descriptor.idProduct, descriptor.bNumConfigurations);

    for (uint8_t config_index = 0; config_index < descriptor.bNumConfigurations; config_index++) {
        struct libusb_config_descriptor *config = NULL;
        status = libusb_get_config_descriptor(device, config_index, &config);
        if (status != LIBUSB_SUCCESS || config == NULL) {
            continue;
        }

        printf("configuration %u interfaces=%u\n", config_index, config->bNumInterfaces);
        for (uint8_t interface_index = 0; interface_index < config->bNumInterfaces; interface_index++) {
            const struct libusb_interface *interface = &config->interface[interface_index];
            for (int alt_index = 0; alt_index < interface->num_altsetting; alt_index++) {
                const struct libusb_interface_descriptor *alt = &interface->altsetting[alt_index];
                printf("  interface=%u alt=%u class=%02x subclass=%02x protocol=%02x endpoints=%u\n",
                       alt->bInterfaceNumber,
                       alt->bAlternateSetting,
                       alt->bInterfaceClass,
                       alt->bInterfaceSubClass,
                       alt->bInterfaceProtocol,
                       alt->bNumEndpoints);

                for (uint8_t endpoint_index = 0; endpoint_index < alt->bNumEndpoints; endpoint_index++) {
                    const struct libusb_endpoint_descriptor *endpoint = &alt->endpoint[endpoint_index];
                    const char *direction = (endpoint->bEndpointAddress & LIBUSB_ENDPOINT_IN) ? "IN" : "OUT";
                    const uint8_t transfer_type = endpoint->bmAttributes & LIBUSB_TRANSFER_TYPE_MASK;
                    const char *type = "unknown";
                    if (transfer_type == LIBUSB_TRANSFER_TYPE_CONTROL) type = "control";
                    if (transfer_type == LIBUSB_TRANSFER_TYPE_ISOCHRONOUS) type = "isochronous";
                    if (transfer_type == LIBUSB_TRANSFER_TYPE_BULK) type = "bulk";
                    if (transfer_type == LIBUSB_TRANSFER_TYPE_INTERRUPT) type = "interrupt";
                    printf("    endpoint=0x%02x %s type=%s maxPacket=%u interval=%u\n",
                           endpoint->bEndpointAddress,
                           direction,
                           type,
                           endpoint->wMaxPacketSize,
                           endpoint->bInterval);
                }
            }
        }
        libusb_free_config_descriptor(config);
    }
}

static void poll_control_events(libusb_device_handle *handle, int duration_seconds) {
    unsigned char previous[4] = {0xff, 0xff, 0xff, 0xff};
    unsigned char current[4] = {0};
    int changes = 0;
    int reads = 0;
    long start = now_ms();
    long end = start + duration_seconds * 1000L;

    printf("polling control get_event bmRequestType=0xa1 bRequest=0x01 wValue=0x0600 wIndex=0x3e00 len=4 duration=%ds\n",
           duration_seconds);
    fflush(stdout);

    while (keep_running && now_ms() < end) {
        int status = libusb_control_transfer(handle, 0xa1, 0x01, 0x0600, 0x3e00, current, sizeof(current), 100);
        reads++;
        if (status < 0) {
            printf("[%ld ms] control read error: %s\n", now_ms() - start, libusb_error_name(status));
            usleep(100000);
            continue;
        }
        if (status == 4 && memcmp(previous, current, sizeof(current)) != 0) {
            changes++;
            printf("[%ld ms] event changed: ", now_ms() - start);
            print_bytes(current, sizeof(current));
            printf("\n");
            memcpy(previous, current, sizeof(previous));
            fflush(stdout);
        }
        usleep(10000);
    }
    printf("control polling done: reads=%d changes=%d last=", reads, changes);
    print_bytes(previous, sizeof(previous));
    printf("\n");
}

static void poll_interrupt_endpoint(libusb_device_handle *handle, int duration_seconds) {
    unsigned char previous[64];
    memset(previous, 0xff, sizeof(previous));
    int changes = 0;
    int reads = 0;
    int timeouts = 0;
    long start = now_ms();
    long end = start + duration_seconds * 1000L;

    libusb_set_auto_detach_kernel_driver(handle, 1);
    int active = libusb_kernel_driver_active(handle, 0);
    if (active == 1) {
        int detach_status = libusb_detach_kernel_driver(handle, 0);
        printf("kernel driver active on interface 0, detach status=%s\n", libusb_error_name(detach_status));
    }

    int status = libusb_claim_interface(handle, 0);
    if (status != LIBUSB_SUCCESS) {
        printf("interrupt endpoint scan skipped: claim interface 0 failed: %s\n", libusb_error_name(status));
        return;
    }

    printf("polling interrupt endpoint 0x83 duration=%ds\n", duration_seconds);
    fflush(stdout);

    while (keep_running && now_ms() < end) {
        unsigned char current[64] = {0};
        int transferred = 0;
        status = libusb_interrupt_transfer(handle, 0x83, current, sizeof(current), &transferred, 100);
        reads++;
        if (status == LIBUSB_ERROR_TIMEOUT) {
            timeouts++;
            continue;
        }
        if (status != LIBUSB_SUCCESS) {
            printf("[%ld ms] interrupt read error: %s\n", now_ms() - start, libusb_error_name(status));
            usleep(100000);
            continue;
        }
        if (transferred > 0 && memcmp(previous, current, (size_t)transferred) != 0) {
            changes++;
            printf("[%ld ms] interrupt changed len=%d: ", now_ms() - start, transferred);
            print_bytes(current, transferred);
            printf("\n");
            memset(previous, 0xff, sizeof(previous));
            memcpy(previous, current, (size_t)transferred);
            fflush(stdout);
        }
    }

    libusb_release_interface(handle, 0);
    printf("interrupt polling done: reads=%d timeouts=%d changes=%d\n", reads, timeouts, changes);
}

struct readable_control {
    uint16_t w_value;
    uint16_t w_index;
    unsigned char previous[4];
    int changes;
};

static void scan_readable_controls(libusb_device_handle *handle, int duration_seconds) {
    const uint16_t indexes[] = {0x2900, 0x3200, 0x3300, 0x3800, 0x3900, 0x3a00, 0x3b00, 0x3c00, 0x3e00};
    struct readable_control controls[2048];
    int control_count = 0;

    printf("probing readable control GET addresses...\n");
    for (size_t index_i = 0; index_i < sizeof(indexes) / sizeof(indexes[0]); index_i++) {
        for (uint16_t base = 0x0000; base <= 0x0700; base += 0x0100) {
            for (uint16_t channel = 0; channel < 16; channel++) {
                uint16_t w_value = (uint16_t)(base + channel);
                unsigned char data[4] = {0};
                int status = libusb_control_transfer(handle, 0xa1, 0x01, w_value, indexes[index_i], data, sizeof(data), 50);
                if (status == 4 && control_count < (int)(sizeof(controls) / sizeof(controls[0]))) {
                    controls[control_count].w_value = w_value;
                    controls[control_count].w_index = indexes[index_i];
                    memcpy(controls[control_count].previous, data, sizeof(data));
                    controls[control_count].changes = 0;
                    control_count++;
                }
            }
        }
    }

    printf("readable controls found=%d\n", control_count);
    for (int i = 0; i < control_count && i < 80; i++) {
        printf("  readable wIndex=0x%04x wValue=0x%04x initial=",
               controls[i].w_index, controls[i].w_value);
        print_bytes(controls[i].previous, 4);
        printf("\n");
    }
    if (control_count > 80) {
        printf("  ... %d more readable controls omitted from initial listing\n", control_count - 80);
    }

    long start = now_ms();
    long end = start + duration_seconds * 1000L;
    int total_changes = 0;
    printf("polling readable controls for changes duration=%ds\n", duration_seconds);
    while (keep_running && now_ms() < end) {
        for (int i = 0; i < control_count; i++) {
            unsigned char data[4] = {0};
            int status = libusb_control_transfer(
                handle,
                0xa1,
                0x01,
                controls[i].w_value,
                controls[i].w_index,
                data,
                sizeof(data),
                50
            );
            if (status == 4 && memcmp(data, controls[i].previous, sizeof(data)) != 0) {
                controls[i].changes++;
                total_changes++;
                printf("[%ld ms] control changed wIndex=0x%04x wValue=0x%04x old=",
                       now_ms() - start, controls[i].w_index, controls[i].w_value);
                print_bytes(controls[i].previous, 4);
                printf(" new=");
                print_bytes(data, 4);
                printf("\n");
                memcpy(controls[i].previous, data, sizeof(data));
                fflush(stdout);
            }
        }
        usleep(50000);
    }
    printf("readable control polling done: totalChanges=%d\n", total_changes);
}

static void probe_get_variants(libusb_device_handle *handle) {
    const uint8_t request_types[] = {0xa1, 0xc1, 0x81};
    const uint8_t requests[] = {0x01, 0x81};
    const uint16_t indexes[] = {0x3a00, 0x3b00, 0x3c00, 0x3e00};
    const uint16_t values[] = {0x0000, 0x0001, 0x0100, 0x0101, 0x0600};
    const uint16_t lengths[] = {1, 2, 3, 4, 6, 8};

    printf("probing GET request variants...\n");
    for (size_t rt = 0; rt < sizeof(request_types) / sizeof(request_types[0]); rt++) {
        for (size_t req = 0; req < sizeof(requests) / sizeof(requests[0]); req++) {
            int hits = 0;
            for (size_t ii = 0; ii < sizeof(indexes) / sizeof(indexes[0]); ii++) {
                for (size_t vi = 0; vi < sizeof(values) / sizeof(values[0]); vi++) {
                    for (size_t li = 0; li < sizeof(lengths) / sizeof(lengths[0]); li++) {
                        unsigned char data[8] = {0};
                        int status = libusb_control_transfer(
                            handle,
                            request_types[rt],
                            requests[req],
                            values[vi],
                            indexes[ii],
                            data,
                            lengths[li],
                            100
                        );
                        if (status > 0) {
                            hits++;
                            printf("  hit bm=0x%02x req=0x%02x wIndex=0x%04x wValue=0x%04x requested=%u returned=%d data=",
                                   request_types[rt], requests[req], indexes[ii], values[vi], lengths[li], status);
                            print_bytes(data, status);
                            printf("\n");
                        }
                    }
                }
            }
            printf("  variant bm=0x%02x req=0x%02x hits=%d\n", request_types[rt], requests[req], hits);
        }
    }
}

int main(int argc, char **argv) {
    int duration_seconds = 10;
    if (argc > 1) {
        duration_seconds = atoi(argv[1]);
        if (duration_seconds <= 0) {
            duration_seconds = 10;
        }
    }

    signal(SIGINT, stop_running);

    int status = libusb_init_context(NULL, NULL, 0);
    if (status != LIBUSB_SUCCESS) {
        fprintf(stderr, "libusb init failed: %s\n", libusb_error_name(status));
        return 1;
    }

    uint16_t product_id = 0;
    libusb_device_handle *handle = open_evo(&product_id);
    if (handle == NULL) {
        fprintf(stderr, "Audient EVO USB device not found\n");
        libusb_exit(NULL);
        return 2;
    }

    printf("opened Audient EVO product=0x%04x\n", product_id);
    print_descriptors(handle);
    probe_get_variants(handle);
    poll_control_events(handle, duration_seconds);
    scan_readable_controls(handle, duration_seconds);
    poll_interrupt_endpoint(handle, duration_seconds);

    libusb_close(handle);
    libusb_exit(NULL);
    return 0;
}
