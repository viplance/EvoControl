// Test whether any mixer slot actually affects audio.
// Strategy: while playing music, mute individual DAW->OUT slots one at a time
// and see if audio cuts out. This identifies which slot carries the DAW signal.
//
// Also tests: write a distinctive pattern to all slots, then read back to
// confirm writes land, then check if any slot "resets" on its own.
//
// Build:
//   cc -o evo_mute_test tools/evo_mute_test.c \
//      -I/opt/homebrew/Cellar/libusb/1.0.30/include/libusb-1.0 \
//      -L/opt/homebrew/lib -lusb-1.0
//
// Run WITHOUT sudo. Play music during the test.

#include <libusb.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

static libusb_device_handle *g_handle = NULL;

static int open_device(void) {
    int status = libusb_init_context(NULL, NULL, 0);
    if (status) { fprintf(stderr, "libusb_init: %s\n", libusb_error_name(status)); return -1; }
    uint16_t pids[] = {0x0006, 0x0007, 0x0008, 0x000a};
    for (int i = 0; i < 4; i++) {
        g_handle = libusb_open_device_with_vid_pid(NULL, 0x2708, pids[i]);
        if (g_handle) { printf("Opened PID=0x%04x\n", pids[i]); return 0; }
    }
    fprintf(stderr, "No EVO device\n"); return -1;
}

static int usb_set(uint16_t wv, uint16_t wi, uint8_t *d, int l) {
    return libusb_control_transfer(g_handle, 0x21, 0x01, wv, wi, d, l, 1000) < 0 ? -1 : 0;
}
static int usb_get(uint16_t wv, uint16_t wi, uint8_t *d, int l) {
    memset(d, 0, l);
    return libusb_control_transfer(g_handle, 0xA1, 0x01, wv, wi, d, l, 100) < 0 ? -1 : 0;
}

int main(void) {
    if (open_device()) return 1;

    uint16_t wi = 0x3C00;
    uint8_t mute[2] = {0x00, 0x80};   // -128 dB
    uint8_t unity[2] = {0x00, 0x00};   // 0 dB

    // --- Part A: Test if the mixer unit is actually in the signal path ---
    // Write distinctive values to all 64 slots, then mute them all.
    printf("\n=== Part A: Muting ALL 64 mixer slots ===\n");
    printf("Play music now. In 3 seconds, all slots will be muted.\n");
    printf("If music stops → mixer IS in the signal path.\n");
    printf("If music continues → mixer is NOT in the DAW output path.\n\n");
    sleep(3);

    // Save originals and mute all
    uint8_t saved[64][2];
    for (int s = 0; s < 64; s++) {
        uint16_t wv = 0x0100 + s;
        usb_get(wv, wi, saved[s], 2);
        usb_set(wv, wi, mute, 2);
    }
    printf("All 64 slots MUTED. Listen for 3 seconds...\n");
    sleep(3);

    // Restore all
    for (int s = 0; s < 64; s++) {
        usb_set(0x0100 + s, wi, saved[s], 2);
    }
    printf("All 64 slots RESTORED.\n\n");

    // --- Part B: If Part A killed audio, identify which slot ---
    printf("=== Part B: Muting slots one-by-one (0.5s each) ===\n");
    printf("If audio cuts on a specific slot, that's the active DAW route.\n\n");

    for (int s = 0; s < 32; s++) {
        uint16_t wv = 0x0100 + s;
        uint8_t orig[2];
        usb_get(wv, wi, orig, 2);
        usb_set(wv, wi, mute, 2);
        printf("  slot 0x%04x MUTED...", wv);
        fflush(stdout);
        usleep(500000);
        usb_set(wv, wi, orig, 2);
        printf(" restored\n");
    }

    // --- Part C: Try wIndex 0x3B00 mute as control ---
    printf("\n=== Part C: Control test — mute output (0x3B00) ===\n");
    printf("This SHOULD kill audio. Testing in 2 seconds...\n");
    sleep(2);

    uint8_t out_orig_l[2], out_orig_r[2];
    usb_get(0x0000, 0x3B00, out_orig_l, 2);
    usb_get(0x0001, 0x3B00, out_orig_r, 2);
    printf("  Output L: [%02x %02x], R: [%02x %02x]\n",
        out_orig_l[0], out_orig_l[1], out_orig_r[0], out_orig_r[1]);

    usb_set(0x0000, 0x3B00, mute, 2);
    usb_set(0x0001, 0x3B00, mute, 2);
    printf("  Output MUTED. Listen for 2 seconds...\n");
    sleep(2);

    usb_set(0x0000, 0x3B00, out_orig_l, 2);
    usb_set(0x0001, 0x3B00, out_orig_r, 2);
    printf("  Output RESTORED.\n");

    libusb_close(g_handle);
    libusb_exit(NULL);
    printf("\nDone.\n");
    return 0;
}
