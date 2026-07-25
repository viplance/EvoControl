// Diagnostic tool for EVO 4 direct monitoring.
//
// Test 1 — Driver override: write a value to 0x3C00, read it back at
//   t=0, t=100ms, t=500ms, t=2000ms. If the value reverts, macOS
//   AppleUSBAudio is overwriting our mixer coefficients.
//
// Test 2 — DAW slots: on the EVO 8, wValue 0x0110..0x0117 route DAW
//   playback through the mixer. If DAW slots exist on EVO 4, writing
//   0 dB there would make playback audible through the mixer output.
//
// Test 3 — Full matrix dump: read all plausible crosspoints to map
//   the EVO 4 mixer dimensions (how many inputs × outputs).
//
// Build:
//   cc -o evo_monitor_diag tools/evo_monitor_diag.c \
//      -I/opt/homebrew/include -L/opt/homebrew/lib -lusb-1.0
//
// Run WITHOUT sudo (to stay alongside the class driver).

#include <libusb.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static libusb_device_handle *g_handle = NULL;

static int open_device(void) {
    int status = libusb_init_context(NULL, NULL, 0);
    if (status != LIBUSB_SUCCESS) {
        fprintf(stderr, "libusb_init: %s\n", libusb_error_name(status));
        return -1;
    }
    uint16_t pids[] = {0x0006, 0x0007, 0x0008, 0x000a};
    for (int i = 0; i < 4; i++) {
        g_handle = libusb_open_device_with_vid_pid(NULL, 0x2708, pids[i]);
        if (g_handle) {
            printf("Opened device VID=0x2708 PID=0x%04x\n", pids[i]);
            return 0;
        }
    }
    fprintf(stderr, "No EVO device found\n");
    return -1;
}

static int usb_set(uint16_t wValue, uint16_t wIndex, uint8_t *data, int len) {
    int r = libusb_control_transfer(g_handle, 0x21, 0x01, wValue, wIndex, data, len, 1000);
    return r < 0 ? r : 0;
}

static int usb_get(uint16_t wValue, uint16_t wIndex, uint8_t *data, int len) {
    memset(data, 0, len);
    int r = libusb_control_transfer(g_handle, 0xA1, 0x01, wValue, wIndex, data, len, 100);
    return r < 0 ? r : 0;
}

static double q8_8_to_db(uint8_t lo, uint8_t hi) {
    int16_t raw = (int16_t)((uint16_t)hi << 8 | lo);
    return raw / 256.0;
}

static void print_db(uint8_t *data, int len) {
    if (len >= 2) {
        printf("[0x%02x 0x%02x] = %.2f dB", data[0], data[1], q8_8_to_db(data[0], data[1]));
    } else {
        printf("[");
        for (int i = 0; i < len; i++) printf("0x%02x ", data[i]);
        printf("]");
    }
}

// ─── Test 1: Write-wait-read ────────────────────────────────────────
static void test_driver_override(void) {
    printf("\n══════════════════════════════════════════════════\n");
    printf("TEST 1: Driver override detection\n");
    printf("══════════════════════════════════════════════════\n\n");

    uint16_t wIndex = 0x3C00;
    uint16_t wValue = 0x0100; // MIC1 -> OUT1

    // First, read the current value
    uint8_t orig[2];
    int r = usb_get(wValue, wIndex, orig, 2);
    if (r < 0) {
        printf("Cannot read 0x3C00/0x0100: %s\n", libusb_error_name(r));
        printf("(Reads may not be supported — skipping override test)\n");
        return;
    }
    printf("Current value at MIC1->OUT1: ");
    print_db(orig, 2);
    printf("\n");

    // Write a distinctive test value: -12 dB = 0xF400
    uint8_t test_val[2] = {0x00, 0xF4}; // -12 dB in Q8.8 LE
    r = usb_set(wValue, wIndex, test_val, 2);
    if (r < 0) {
        printf("Write failed: %s\n", libusb_error_name(r));
        return;
    }
    printf("Wrote -12.00 dB [0x00 0xF4]\n\n");

    int delays_ms[] = {0, 100, 500, 2000};
    int overwritten = 0;
    for (int i = 0; i < 4; i++) {
        if (delays_ms[i] > 0) usleep(delays_ms[i] * 1000);
        uint8_t readback[2];
        r = usb_get(wValue, wIndex, readback, 2);
        if (r < 0) {
            printf("  t=%4dms: read failed: %s\n", delays_ms[i], libusb_error_name(r));
            continue;
        }
        int match = (readback[0] == test_val[0] && readback[1] == test_val[1]);
        printf("  t=%4dms: ", delays_ms[i]);
        print_db(readback, 2);
        printf("  %s\n", match ? "✓ holds" : "✗ CHANGED — driver override!");
        if (!match) overwritten = 1;
    }

    // Restore original value
    usb_set(wValue, wIndex, orig, 2);
    printf("\nRestored original value.\n");

    if (overwritten) {
        printf("\n>>> RESULT: macOS driver IS overwriting mixer coefficients.\n");
    } else {
        printf("\n>>> RESULT: Values persist — driver is NOT overwriting.\n");
        printf("    The silence has another cause.\n");
    }
}

// ─── Test 2: DAW slots ─────────────────────────────────────────────
static void test_daw_slots(void) {
    printf("\n══════════════════════════════════════════════════\n");
    printf("TEST 2: DAW playback slots in mixer matrix\n");
    printf("══════════════════════════════════════════════════\n\n");

    uint16_t wIndex = 0x3C00;
    // On EVO 8: DAW1->OUT1 = 0x0110, DAW1->OUT2 = 0x0111
    // On EVO 4 (2 inputs, possibly stride 2): DAW1 might start at 0x0104
    // Test both possibilities.

    struct { uint16_t wValue; const char *label; } slots[] = {
        // EVO 8 layout (stride 4): DAW slots start at input index 4
        {0x0110, "DAW1->OUT1 (EVO8 layout)"},
        {0x0111, "DAW1->OUT2 (EVO8 layout)"},
        {0x0114, "DAW2->OUT1 (EVO8 layout)"},
        {0x0115, "DAW2->OUT2 (EVO8 layout)"},
        // EVO 4 possible layout (stride 2): DAW starts at input index 2
        {0x0104, "DAW1->OUT1 (if stride=2)"},
        {0x0105, "DAW1->OUT2 (if stride=2)"},
        {0x0106, "DAW2->OUT1 (if stride=2)"},
        {0x0107, "DAW2->OUT2 (if stride=2)"},
        // EVO 4 possible layout (stride 4, 2 mic inputs):
        // MIC slots we already know
        {0x0100, "MIC1->OUT1"},
        {0x0101, "MIC1->OUT2"},
        {0x0104, "MIC2->OUT1 / DAW1->OUT1(stride2)"},
        {0x0105, "MIC2->OUT2 / DAW1->OUT2(stride2)"},
        {0x0108, "input3->OUT1 (DAW1 if stride4, 2mic)"},
        {0x0109, "input3->OUT2 (DAW1 if stride4, 2mic)"},
        {0x010C, "input4->OUT1 (DAW2 if stride4, 2mic)"},
        {0x010D, "input4->OUT2 (DAW2 if stride4, 2mic)"},
    };

    printf("Reading current values of all candidate DAW slots:\n\n");
    for (int i = 0; i < (int)(sizeof(slots)/sizeof(slots[0])); i++) {
        uint8_t data[2];
        int r = usb_get(slots[i].wValue, wIndex, data, 2);
        if (r < 0) {
            printf("  0x%04x %-40s  ERROR: %s\n", slots[i].wValue, slots[i].label, libusb_error_name(r));
        } else {
            printf("  0x%04x %-40s  ", slots[i].wValue, slots[i].label);
            print_db(data, 2);
            printf("\n");
        }
    }
}

// ─── Test 3: Full matrix scan ───────────────────────────────────────
static void test_matrix_scan(void) {
    printf("\n══════════════════════════════════════════════════\n");
    printf("TEST 3: Full mixer matrix scan (0x3C00)\n");
    printf("══════════════════════════════════════════════════\n\n");

    uint16_t wIndex = 0x3C00;
    int readable = 0, errors = 0;
    int first_error_at = -1;

    printf("Scanning wValue 0x0100..0x013F (64 slots = 16 inputs x 4 outputs max):\n\n");
    printf("  wValue  | bytes      | dB       | status\n");
    printf("  --------+------------+----------+--------\n");

    for (int slot = 0; slot < 64; slot++) {
        uint16_t wValue = 0x0100 + slot;
        uint8_t data[2];
        int r = usb_get(wValue, wIndex, data, 2);
        if (r < 0) {
            if (first_error_at < 0) first_error_at = slot;
            errors++;
            if (errors <= 5 || slot < 20) {
                printf("  0x%04x  |            |          | %s\n", wValue, libusb_error_name(r));
            }
        } else {
            readable++;
            double db = q8_8_to_db(data[0], data[1]);
            printf("  0x%04x  | %02x %02x      | %7.2f  | ok\n", wValue, data[0], data[1], db);
        }
    }

    printf("\n  Readable: %d, Errors: %d", readable, errors);
    if (first_error_at >= 0) printf(", first error at slot %d (0x%04x)", first_error_at, 0x0100 + first_error_at);
    printf("\n");

    if (readable > 0) {
        // Infer dimensions
        // If all 64 readable → huge mixer. More likely some subset.
        int outs = 0;
        if (readable <= 8) outs = 2;
        else if (readable <= 16) outs = 4;
        int ins = outs > 0 ? readable / outs : 0;
        if (ins > 0 && outs > 0) {
            printf("\n  Inferred matrix: %d inputs x %d outputs\n", ins, outs);
            printf("  (If %d outputs, input stride = %d)\n", outs, outs);
        }
    }
}

// ─── Test 4: Read wIndex 0x3200 (Extension Unit 50) ─────────────────
static void test_extension_unit(void) {
    printf("\n══════════════════════════════════════════════════\n");
    printf("TEST 4: Extension Unit 50 (0x3200) probe\n");
    printf("══════════════════════════════════════════════════\n\n");

    printf("Scanning wValue 0x0000..0x000F at wIndex 0x3200 (2-byte reads):\n\n");
    for (int v = 0; v < 16; v++) {
        uint16_t wValue = v;
        uint8_t data[2];
        int r = usb_get(wValue, 0x3200, data, 2);
        if (r < 0) {
            printf("  0x%04x: %s\n", wValue, libusb_error_name(r));
        } else {
            printf("  0x%04x: ", wValue);
            print_db(data, 2);
            printf("\n");
        }
    }
}

int main(void) {
    printf("EVO 4 Monitor Mix Diagnostic\n");
    printf("════════════════════════════\n");

    if (open_device() != 0) return 1;

    test_driver_override();
    test_daw_slots();
    test_matrix_scan();
    test_extension_unit();

    libusb_close(g_handle);
    libusb_exit(NULL);

    printf("\n\nDone.\n");
    return 0;
}
