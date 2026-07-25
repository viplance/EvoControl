#import "CEvoAudioTap.h"

#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Foundation/Foundation.h>

struct EvoAudioTapMeter {
    AudioObjectID tapID;
    AudioObjectID aggregateID;
    AudioDeviceIOProcID ioProcID;
    CATapDescription *tapDescription;
    dispatch_queue_t queue;
    EvoAudioTapLevelCallback levelCallback;
    EvoAudioTapLogCallback logCallback;
    void *context;
    UInt32 channelCount;
    UInt64 callbackCount;
    UInt64 nonZeroSamples;
    UInt32 selectedBufferIndex;
    bool running;
};

static void EvoTapLog(EvoAudioTapMeter *meter, NSString *message) {
    if (meter == NULL || meter->logCallback == NULL) {
        return;
    }
    meter->logCallback(message.UTF8String, meter->context);
}

static AudioStreamBasicDescription EvoTapFormat(AudioObjectID tapID) {
    AudioStreamBasicDescription format = {0};
    AudioObjectPropertyAddress address = {
        kAudioTapPropertyFormat,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = sizeof(format);
    AudioObjectGetPropertyData(tapID, &address, 0, NULL, &size, &format);
    return format;
}

static void EvoTapRecord(EvoAudioTapMeter *meter, const AudioBufferList *inputData) {
    if (meter == NULL || inputData == NULL || meter->levelCallback == NULL) {
        return;
    }

    Float32 levels[16] = {0};
    const AudioBuffer *tapBuffer = NULL;
    UInt32 tapBufferIndex = 0;
    for (UInt32 bufferIndex = 0; bufferIndex < inputData->mNumberBuffers; bufferIndex++) {
        const AudioBuffer *buffer = &inputData->mBuffers[bufferIndex];
        if (buffer->mData != NULL && buffer->mDataByteSize > 0 && buffer->mNumberChannels > 0) {
            tapBuffer = buffer;
            tapBufferIndex = bufferIndex;
        }
    }
    if (tapBuffer == NULL) {
        return;
    }

    UInt32 frames = 0;
    frames = tapBuffer->mDataByteSize / (UInt32)(sizeof(Float32) * tapBuffer->mNumberChannels);
    if (frames == 0) {
        return;
    }

    meter->callbackCount += 1;
    meter->selectedBufferIndex = tapBufferIndex;
    const Float32 *samples = tapBuffer->mData;
    for (UInt32 channel = 0; channel < tapBuffer->mNumberChannels && channel < meter->channelCount && channel < 16; channel++) {
        Float32 peak = 0;
        for (UInt32 frame = 0; frame < frames; frame++) {
            Float32 sample = samples[(frame * tapBuffer->mNumberChannels) + channel];
            Float32 absolute = fabsf(sample);
            if (absolute > peak) {
                peak = absolute;
            }
            if (absolute > 0.0000001f) {
                meter->nonZeroSamples += 1;
            }
        }
        levels[channel] = peak;
    }

    meter->levelCallback(levels, (int32_t)meter->channelCount, meter->context);

    if (meter->callbackCount <= 5 || meter->callbackCount % 250 == 0) {
        NSMutableArray<NSString *> *parts = [NSMutableArray arrayWithCapacity:meter->channelCount];
        for (UInt32 index = 0; index < meter->channelCount; index++) {
            [parts addObject:[NSString stringWithFormat:@"ch%u=%.5f", index + 1, levels[index]]];
        }
        EvoTapLog(
            meter,
            [NSString stringWithFormat:@"tap callback=%llu buffers=%u selectedBuffer=%u nonZero=%llu %@",
             meter->callbackCount,
             inputData->mNumberBuffers,
             meter->selectedBufferIndex,
             meter->nonZeroSamples,
             [parts componentsJoinedByString:@" "]]
        );
    }
}

EvoAudioTapMeter *evo_audio_tap_create(void) {
    EvoAudioTapMeter *meter = calloc(1, sizeof(EvoAudioTapMeter));
    meter->tapID = kAudioObjectUnknown;
    meter->aggregateID = kAudioObjectUnknown;
    meter->ioProcID = NULL;
    meter->channelCount = 2;
    meter->selectedBufferIndex = 0;
    return meter;
}

bool evo_audio_tap_start(EvoAudioTapMeter *meter,
                         const char *deviceUID,
                         EvoAudioTapLevelCallback levelCallback,
                         EvoAudioTapLogCallback logCallback,
                         void *context) {
    if (meter == NULL || deviceUID == NULL || levelCallback == NULL) {
        return false;
    }

    evo_audio_tap_stop(meter);
    meter->levelCallback = levelCallback;
    meter->logCallback = logCallback;
    meter->context = context;
    meter->callbackCount = 0;
    meter->nonZeroSamples = 0;

    @autoreleasepool {
        if (@available(macOS 14.2, *)) {
        } else {
            EvoTapLog(meter, @"process taps require macOS 14.2 or newer");
            return false;
        }

        NSString *uid = [NSString stringWithUTF8String:deviceUID];
        EvoTapLog(meter, [NSString stringWithFormat:@"starting process tap for uid=%@", uid]);

        CATapDescription *tapDescription = [[CATapDescription alloc] initExcludingProcesses:@[] andDeviceUID:uid withStream:0];
        tapDescription.name = @"Evo Control Output Meter";
        tapDescription.privateTap = YES;
        tapDescription.muteBehavior = CATapUnmuted;
        meter->tapDescription = tapDescription;

        OSStatus status = AudioHardwareCreateProcessTap(tapDescription, &meter->tapID);
        if (status != noErr) {
            EvoTapLog(meter, [NSString stringWithFormat:@"AudioHardwareCreateProcessTap failed OSStatus=%d", status]);
            return false;
        }

        AudioStreamBasicDescription format = EvoTapFormat(meter->tapID);
        meter->channelCount = MIN(MAX(format.mChannelsPerFrame, 1), 16);
        EvoTapLog(
            meter,
            [NSString stringWithFormat:@"tap=%u uuid=%@ channels=%u sampleRate=%.1f formatID=%u flags=0x%x",
             meter->tapID,
             tapDescription.UUID.UUIDString,
             meter->channelCount,
             format.mSampleRate,
             format.mFormatID,
             format.mFormatFlags]
        );

        NSString *aggregateUID = [NSString stringWithFormat:@"local.evo-control.output-meter.%@", NSUUID.UUID.UUIDString];
        NSDictionary *description = @{
            @kAudioAggregateDeviceNameKey: @"Evo Control Output Meter",
            @kAudioAggregateDeviceUIDKey: aggregateUID,
            @kAudioAggregateDeviceIsPrivateKey: @YES,
            @kAudioAggregateDeviceSubDeviceListKey: @[
                @{ @kAudioSubDeviceUIDKey: uid }
            ],
            @kAudioAggregateDeviceMainSubDeviceKey: uid,
            @kAudioAggregateDeviceClockDeviceKey: uid,
            @kAudioAggregateDeviceTapAutoStartKey: @NO,
            @kAudioAggregateDeviceTapListKey: @[
                @{
                    @kAudioSubTapUIDKey: tapDescription.UUID.UUIDString,
                    @kAudioSubTapDriftCompensationKey: @YES
                }
            ]
        };

        status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)description, &meter->aggregateID);
        if (status != noErr) {
            EvoTapLog(meter, [NSString stringWithFormat:@"AudioHardwareCreateAggregateDevice failed OSStatus=%d", status]);
            evo_audio_tap_stop(meter);
            return false;
        }

        meter->queue = dispatch_queue_create("local.evo-control.output-meter", DISPATCH_QUEUE_SERIAL);
        EvoAudioTapMeter *capturedMeter = meter;
        status = AudioDeviceCreateIOProcIDWithBlock(
            &meter->ioProcID,
            meter->aggregateID,
            meter->queue,
            ^(const AudioTimeStamp *now,
              const AudioBufferList *inputData,
              const AudioTimeStamp *inputTime,
              AudioBufferList *outputData,
              const AudioTimeStamp *outputTime) {
                (void)now;
                (void)inputTime;
                (void)outputData;
                (void)outputTime;
                EvoTapRecord(capturedMeter, inputData);
            }
        );
        if (status != noErr) {
            EvoTapLog(meter, [NSString stringWithFormat:@"AudioDeviceCreateIOProcIDWithBlock failed OSStatus=%d", status]);
            evo_audio_tap_stop(meter);
            return false;
        }

        status = AudioDeviceStart(meter->aggregateID, meter->ioProcID);
        if (status != noErr) {
            EvoTapLog(meter, [NSString stringWithFormat:@"AudioDeviceStart failed OSStatus=%d", status]);
            evo_audio_tap_stop(meter);
            return false;
        }

        meter->running = true;
        EvoTapLog(meter, @"process tap started");
        return true;
    }
}

void evo_audio_tap_stop(EvoAudioTapMeter *meter) {
    if (meter == NULL) {
        return;
    }
    @autoreleasepool {
        if (meter->running && meter->aggregateID != kAudioObjectUnknown && meter->ioProcID != NULL) {
            AudioDeviceStop(meter->aggregateID, meter->ioProcID);
        }
        if (meter->aggregateID != kAudioObjectUnknown && meter->ioProcID != NULL) {
            AudioDeviceDestroyIOProcID(meter->aggregateID, meter->ioProcID);
        }
        if (meter->aggregateID != kAudioObjectUnknown) {
            AudioHardwareDestroyAggregateDevice(meter->aggregateID);
        }
        if (@available(macOS 14.2, *)) {
        if (meter->tapID != kAudioObjectUnknown) {
            AudioHardwareDestroyProcessTap(meter->tapID);
        }
        }
        if (meter->running || meter->callbackCount > 0) {
            EvoTapLog(
                meter,
                [NSString stringWithFormat:@"process tap stopped callbacks=%llu nonZero=%llu",
                 meter->callbackCount,
                 meter->nonZeroSamples]
            );
        }
        meter->tapID = kAudioObjectUnknown;
        meter->aggregateID = kAudioObjectUnknown;
        meter->ioProcID = NULL;
        meter->tapDescription = nil;
        meter->queue = nil;
        meter->running = false;
    }
}

void evo_audio_tap_destroy(EvoAudioTapMeter *meter) {
    if (meter == NULL) {
        return;
    }
    evo_audio_tap_stop(meter);
    free(meter);
}
