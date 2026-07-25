#ifndef CEvoAudioTap_h
#define CEvoAudioTap_h

#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef void (*EvoAudioTapLevelCallback)(const float *levels, int32_t channelCount, void *context);
typedef void (*EvoAudioTapLogCallback)(const char *message, void *context);

typedef struct EvoAudioTapMeter EvoAudioTapMeter;

EvoAudioTapMeter *evo_audio_tap_create(void);

bool evo_audio_tap_start(EvoAudioTapMeter *meter,
                         const char *deviceUID,
                         EvoAudioTapLevelCallback levelCallback,
                         EvoAudioTapLogCallback logCallback,
                         void *context);

void evo_audio_tap_stop(EvoAudioTapMeter *meter);
void evo_audio_tap_destroy(EvoAudioTapMeter *meter);

#ifdef __cplusplus
}
#endif

#endif
