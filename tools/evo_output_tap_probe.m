#import <AudioToolbox/AudioToolbox.h>
#import <AudioUnit/AudioUnit.h>
#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Foundation/Foundation.h>

static NSString *StringProperty(AudioObjectID objectID, AudioObjectPropertySelector selector) {
    AudioObjectPropertyAddress address = { selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
    if (!AudioObjectHasProperty(objectID, &address)) {
        return @"";
    }
    CFStringRef value = NULL;
    UInt32 size = sizeof(value);
    OSStatus status = AudioObjectGetPropertyData(objectID, &address, 0, NULL, &size, &value);
    if (status != noErr || value == NULL) {
        return @"";
    }
    return CFBridgingRelease(value);
}

static NSArray<NSNumber *> *AllDevices(void) {
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDevices,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, NULL, &size) != noErr) {
        return @[];
    }
    NSUInteger count = size / sizeof(AudioObjectID);
    AudioObjectID *devices = calloc(count, sizeof(AudioObjectID));
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, devices) != noErr) {
        free(devices);
        return @[];
    }
    NSMutableArray<NSNumber *> *result = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger index = 0; index < count; index++) {
        [result addObject:@(devices[index])];
    }
    free(devices);
    return result;
}

static UInt32 ChannelCount(AudioObjectID deviceID, AudioObjectPropertyScope scope) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyStreamConfiguration,
        scope,
        kAudioObjectPropertyElementMain
    };
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(deviceID, &address, 0, NULL, &size) != noErr || size == 0) {
        return 0;
    }
    AudioBufferList *list = malloc(size);
    if (AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, list) != noErr) {
        free(list);
        return 0;
    }
    UInt32 channels = 0;
    for (UInt32 index = 0; index < list->mNumberBuffers; index++) {
        channels += list->mBuffers[index].mNumberChannels;
    }
    free(list);
    return channels;
}

static Float64 SampleRate(AudioObjectID deviceID) {
    AudioObjectPropertyAddress address = {
        kAudioDevicePropertyNominalSampleRate,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    Float64 value = 48000.0;
    UInt32 size = sizeof(value);
    AudioObjectGetPropertyData(deviceID, &address, 0, NULL, &size, &value);
    return value;
}

static AudioObjectID DefaultOutputDevice(void) {
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectID deviceID = kAudioObjectUnknown;
    UInt32 size = sizeof(deviceID);
    OSStatus status = AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, &size, &deviceID);
    return status == noErr ? deviceID : kAudioObjectUnknown;
}

static OSStatus SetDefaultOutputDevice(AudioObjectID deviceID) {
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyDefaultOutputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    return AudioObjectSetPropertyData(kAudioObjectSystemObject, &address, 0, NULL, sizeof(deviceID), &deviceID);
}

static AudioObjectID ProcessObjectForPID(pid_t pid) {
    AudioObjectPropertyAddress address = {
        kAudioHardwarePropertyTranslatePIDToProcessObject,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMain
    };
    AudioObjectID processObject = kAudioObjectUnknown;
    UInt32 size = sizeof(processObject);
    OSStatus status = AudioObjectGetPropertyData(
        kAudioObjectSystemObject,
        &address,
        sizeof(pid),
        &pid,
        &size,
        &processObject
    );
    if (status != noErr) {
        return kAudioObjectUnknown;
    }
    return processObject;
}

static AudioStreamBasicDescription FloatFormat(Float64 sampleRate, UInt32 channels) {
    AudioStreamBasicDescription format = {0};
    format.mSampleRate = sampleRate;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved;
    format.mBytesPerPacket = sizeof(Float32);
    format.mFramesPerPacket = 1;
    format.mBytesPerFrame = sizeof(Float32);
    format.mChannelsPerFrame = channels;
    format.mBitsPerChannel = 32;
    return format;
}

static AudioUnit MakeHALUnit(void) {
    AudioComponentDescription desc = {
        kAudioUnitType_Output,
        kAudioUnitSubType_HALOutput,
        kAudioUnitManufacturer_Apple,
        0,
        0
    };
    AudioComponent component = AudioComponentFindNext(NULL, &desc);
    AudioUnit unit = NULL;
    OSStatus status = AudioComponentInstanceNew(component, &unit);
    if (status != noErr || unit == NULL) {
        fprintf(stderr, "AudioComponentInstanceNew failed %d\n", status);
        exit(1);
    }
    return unit;
}

static AudioUnit MakeDefaultOutputUnit(void) {
    AudioComponentDescription desc = {
        kAudioUnitType_Output,
        kAudioUnitSubType_DefaultOutput,
        kAudioUnitManufacturer_Apple,
        0,
        0
    };
    AudioComponent component = AudioComponentFindNext(NULL, &desc);
    AudioUnit unit = NULL;
    OSStatus status = AudioComponentInstanceNew(component, &unit);
    if (status != noErr || unit == NULL) {
        fprintf(stderr, "DefaultOutput AudioComponentInstanceNew failed %d\n", status);
        exit(1);
    }
    return unit;
}

static void SetUInt32(AudioUnit unit, AudioUnitPropertyID property, AudioUnitScope scope, AudioUnitElement element, UInt32 value) {
    OSStatus status = AudioUnitSetProperty(unit, property, scope, element, &value, sizeof(value));
    if (status != noErr) {
        fprintf(stderr, "AudioUnitSetProperty %u failed %d\n", property, status);
        exit(1);
    }
}

typedef struct {
    Float64 sampleRate;
    UInt32 tapChannels;
    UInt32 outputChannels;
    double phase;
    UInt64 tapCallbacks;
    UInt64 outputCallbacks;
    UInt64 tapSamples;
    UInt64 buffersWithData;
    UInt64 nonZeroSamples;
    double peak[16];
    double rmsSum[16];
} ProbeState;

static OSStatus OutputCallback(void *refCon,
                               AudioUnitRenderActionFlags *flags,
                               const AudioTimeStamp *timestamp,
                               UInt32 busNumber,
                               UInt32 frameCount,
                               AudioBufferList *ioData) {
    (void)flags;
    (void)timestamp;
    (void)busNumber;
    ProbeState *state = refCon;
    double frequency = 997.0;
    double increment = 2.0 * M_PI * frequency / state->sampleRate;
    for (UInt32 bufferIndex = 0; bufferIndex < ioData->mNumberBuffers; bufferIndex++) {
        Float32 *samples = ioData->mBuffers[bufferIndex].mData;
        if (samples == NULL) {
            continue;
        }
        for (UInt32 frame = 0; frame < frameCount; frame++) {
            samples[frame] = bufferIndex < 2 ? (Float32)(sin(state->phase) * 0.18) : 0.0f;
            if (bufferIndex == 0) {
                state->phase += increment;
                if (state->phase > 2.0 * M_PI) {
                    state->phase -= 2.0 * M_PI;
                }
            }
        }
    }
    state->outputCallbacks += 1;
    return noErr;
}

static void RecordInputData(ProbeState *state, const AudioBufferList *inputData) {
    if (inputData == NULL) {
        return;
    }
    UInt32 frames = 0;
    for (UInt32 bufferIndex = 0; bufferIndex < inputData->mNumberBuffers; bufferIndex++) {
        const AudioBuffer *buffer = &inputData->mBuffers[bufferIndex];
        if (buffer->mData != NULL && buffer->mNumberChannels > 0) {
            frames = buffer->mDataByteSize / (UInt32)(sizeof(Float32) * buffer->mNumberChannels);
            break;
        }
    }
    if (frames == 0) {
        return;
    }
    state->tapCallbacks += 1;
    state->tapSamples += frames;
    UInt32 channelBase = 0;
    for (UInt32 bufferIndex = 0; bufferIndex < inputData->mNumberBuffers; bufferIndex++) {
        const AudioBuffer *buffer = &inputData->mBuffers[bufferIndex];
        const Float32 *samples = buffer->mData;
        if (samples == NULL) {
            channelBase += buffer->mNumberChannels;
            continue;
        }
        for (UInt32 localChannel = 0; localChannel < buffer->mNumberChannels; localChannel++) {
            UInt32 channel = channelBase + localChannel;
            if (channel >= state->tapChannels || channel >= 16) {
                continue;
            }
            double peak = 0.0;
            double sum = 0.0;
            for (UInt32 frame = 0; frame < frames; frame++) {
                double sample = samples[(frame * buffer->mNumberChannels) + localChannel];
                double absSample = fabs(sample);
                if (absSample > peak) {
                    peak = absSample;
                }
                sum += sample * sample;
                if (absSample > 0.0000001) {
                    state->nonZeroSamples += 1;
                }
            }
            if (peak > state->peak[channel]) {
                state->peak[channel] = peak;
            }
            state->rmsSum[channel] += sum;
        }
        if (buffer->mData != NULL && buffer->mDataByteSize > 0) {
            state->buffersWithData += 1;
        }
        channelBase += buffer->mNumberChannels;
    }
}

static OSStatus TapIOProc(AudioObjectID deviceID,
                          const AudioTimeStamp *now,
                          const AudioBufferList *inputData,
                          const AudioTimeStamp *inputTime,
                          AudioBufferList *outputData,
                          const AudioTimeStamp *outputTime,
                          void *clientData) {
    (void)deviceID;
    (void)now;
    (void)inputTime;
    (void)outputData;
    (void)outputTime;
    ProbeState *state = clientData;
    RecordInputData(state, inputData);
    return noErr;
}

static const char *DB(double value, char *buffer, size_t size) {
    if (value <= 0.0000001) {
        snprintf(buffer, size, "-inf");
    } else {
        snprintf(buffer, size, "%.1f", 20.0 * log10(value));
    }
    return buffer;
}

#define STEP(...) do { fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); fflush(stderr); } while (0)

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        STEP("probe start");
        NSTimeInterval duration = argc > 1 ? atof(argv[1]) : 6.0;
        AudioObjectID evoDevice = kAudioObjectUnknown;
        STEP("listing CoreAudio devices");
        for (NSNumber *number in AllDevices()) {
            AudioObjectID deviceID = number.unsignedIntValue;
            NSString *text = [[NSString stringWithFormat:@"%@ %@", StringProperty(deviceID, kAudioObjectPropertyManufacturer), StringProperty(deviceID, kAudioObjectPropertyName)] lowercaseString];
            if ([text containsString:@"audient"] || [text containsString:@"evo"]) {
                evoDevice = deviceID;
                break;
            }
        }
        if (evoDevice == kAudioObjectUnknown) {
            fprintf(stderr, "Audient EVO device not found\n");
            return 1;
        }

        NSString *name = StringProperty(evoDevice, kAudioObjectPropertyName);
        NSString *manufacturer = StringProperty(evoDevice, kAudioObjectPropertyManufacturer);
        NSString *uid = StringProperty(evoDevice, kAudioDevicePropertyDeviceUID);
        Float64 sampleRate = SampleRate(evoDevice);
        UInt32 outputChannels = MAX(1, ChannelCount(evoDevice, kAudioDevicePropertyScopeOutput));
        AudioObjectID previousDefaultOutput = DefaultOutputDevice();
        OSStatus status = noErr;
        STEP("device=%u %s %s uid=%s sampleRate=%.1f outputChannels=%u",
               evoDevice,
               manufacturer.UTF8String,
               name.UTF8String,
               uid.UTF8String,
               sampleRate,
               outputChannels);
        STEP("previousDefaultOutput=%u; setting default output to EVO for probe", previousDefaultOutput);
        status = SetDefaultOutputDevice(evoDevice);
        if (status != noErr) {
            fprintf(stderr, "SetDefaultOutputDevice failed %d\n", status);
            return 1;
        }

        BOOL useGlobalTap = [[[NSProcessInfo processInfo] environment][@"EVO_TAP_GLOBAL"] isEqualToString:@"1"];
        AudioObjectID ownProcess = ProcessObjectForPID(getpid());
        STEP("creating CATapDescription ownProcess=%u global=%s", ownProcess, useGlobalTap ? "yes" : "no");
        CATapDescription *tapDescription = (useGlobalTap || ownProcess == kAudioObjectUnknown)
            ? [[CATapDescription alloc] initExcludingProcesses:@[] andDeviceUID:uid withStream:0]
            : [[CATapDescription alloc] initWithProcesses:@[@(ownProcess)] andDeviceUID:uid withStream:0];
        tapDescription.name = @"Evo Output Tap Probe";
        tapDescription.privateTap = YES;
        tapDescription.muteBehavior = CATapUnmuted;

        STEP("calling AudioHardwareCreateProcessTap");
        AudioObjectID tapID = kAudioObjectUnknown;
        status = AudioHardwareCreateProcessTap(tapDescription, &tapID);
        if (status != noErr) {
            fprintf(stderr, "AudioHardwareCreateProcessTap failed %d\n", status);
            return 1;
        }

        AudioObjectPropertyAddress tapFormatAddress = {
            kAudioTapPropertyFormat,
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        AudioStreamBasicDescription tapFormat = {0};
        UInt32 tapFormatSize = sizeof(tapFormat);
        status = AudioObjectGetPropertyData(tapID, &tapFormatAddress, 0, NULL, &tapFormatSize, &tapFormat);
        if (status != noErr) {
            fprintf(stderr, "kAudioTapPropertyFormat failed %d\n", status);
            AudioHardwareDestroyProcessTap(tapID);
            return 1;
        }
        UInt32 tapChannels = MAX(1, tapFormat.mChannelsPerFrame);
        STEP("tap=%u uuid=%s tapChannels=%u tapSampleRate=%.1f formatID=%u flags=0x%x bits=%u bytesPerFrame=%u",
               tapID,
               tapDescription.UUID.UUIDString.UTF8String,
               tapChannels,
               tapFormat.mSampleRate,
               tapFormat.mFormatID,
               tapFormat.mFormatFlags,
               tapFormat.mBitsPerChannel,
               tapFormat.mBytesPerFrame);

        NSString *aggregateUID = [NSString stringWithFormat:@"local.evo-control.output-tap-probe.%@", NSUUID.UUID.UUIDString];
        NSDictionary *aggregateDescription = @{
            @kAudioAggregateDeviceNameKey: @"Evo Output Tap Probe",
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

        STEP("calling AudioHardwareCreateAggregateDevice");
        AudioObjectID aggregateDevice = kAudioObjectUnknown;
        status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggregateDescription, &aggregateDevice);
        if (status != noErr) {
            fprintf(stderr, "AudioHardwareCreateAggregateDevice failed %d\n", status);
            AudioHardwareDestroyProcessTap(tapID);
            return 1;
        }
        STEP("aggregate=%u capturing process tap and playing 997Hz to EVO for %.1fs", aggregateDevice, duration);

        ProbeState state = {0};
        state.sampleRate = sampleRate;
        state.tapChannels = MIN(tapChannels, 16);
        state.outputChannels = outputChannels;
        ProbeState *statePointer = &state;

        AudioUnit outputUnit = MakeDefaultOutputUnit();

        STEP("setting default output stream format");
        AudioStreamBasicDescription outputFormat = FloatFormat(sampleRate, 2);
        status = AudioUnitSetProperty(outputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &outputFormat, sizeof(outputFormat));
        if (status != noErr) {
            fprintf(stderr, "set output stream format failed %d\n", status);
            return 1;
        }

        STEP("creating tap IOProc block");
        AudioDeviceIOProcID tapIOProcID = NULL;
        dispatch_queue_t tapQueue = dispatch_queue_create("local.evo-control.output-tap-probe", DISPATCH_QUEUE_SERIAL);
        status = AudioDeviceCreateIOProcIDWithBlock(&tapIOProcID, aggregateDevice, tapQueue, ^(
            const AudioTimeStamp *now,
            const AudioBufferList *inputData,
            const AudioTimeStamp *inputTime,
            AudioBufferList *outputData,
            const AudioTimeStamp *outputTime
        ) {
            (void)now;
            (void)inputTime;
            (void)outputData;
            (void)outputTime;
            RecordInputData(statePointer, inputData);
        });
        if (status != noErr) {
            fprintf(stderr, "AudioDeviceCreateIOProcIDWithBlock failed %d\n", status);
            return 1;
        }
        STEP("installing output callback");
        AURenderCallbackStruct outputCallback = { OutputCallback, &state };
        status = AudioUnitSetProperty(outputUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &outputCallback, sizeof(outputCallback));
        if (status != noErr) {
            fprintf(stderr, "install output callback failed %d\n", status);
            return 1;
        }

        STEP("initializing output unit");
        status = AudioUnitInitialize(outputUnit);
        if (status != noErr) {
            fprintf(stderr, "initialize output unit failed %d\n", status);
            return 1;
        }
        STEP("starting tap aggregate");
        status = AudioDeviceStart(aggregateDevice, tapIOProcID);
        if (status != noErr) {
            fprintf(stderr, "AudioDeviceStart tap aggregate failed %d\n", status);
            return 1;
        }
        STEP("starting output unit");
        status = AudioOutputUnitStart(outputUnit);
        if (status != noErr) {
            fprintf(stderr, "start output unit failed %d\n", status);
            return 1;
        }

        NSDate *started = [NSDate date];
        while ([[NSDate date] timeIntervalSinceDate:started] < duration) {
            [NSThread sleepForTimeInterval:0.5];
            printf("live t=%.1fs", [[NSDate date] timeIntervalSinceDate:started]);
            for (UInt32 channel = 0; channel < state.tapChannels; channel++) {
                char dbBuffer[32];
                printf(" ch%u=%sdB", channel + 1, DB(state.peak[channel], dbBuffer, sizeof(dbBuffer)));
            }
            printf("\n");
            fflush(stdout);
        }

        AudioOutputUnitStop(outputUnit);
        AudioDeviceStop(aggregateDevice, tapIOProcID);
        AudioUnitUninitialize(outputUnit);
        AudioComponentInstanceDispose(outputUnit);
        AudioDeviceDestroyIOProcID(aggregateDevice, tapIOProcID);
        AudioHardwareDestroyAggregateDevice(aggregateDevice);
        AudioHardwareDestroyProcessTap(tapID);
        if (previousDefaultOutput != kAudioObjectUnknown && previousDefaultOutput != evoDevice) {
            STEP("restoring previous default output=%u", previousDefaultOutput);
            SetDefaultOutputDevice(previousDefaultOutput);
        }

        printf("summary outputCallbacks=%llu tapCallbacks=%llu buffersWithData=%llu nonZeroSamples=%llu",
               state.outputCallbacks,
               state.tapCallbacks,
               state.buffersWithData,
               state.nonZeroSamples);
        for (UInt32 channel = 0; channel < state.tapChannels; channel++) {
            double rms = state.tapSamples > 0 ? sqrt(state.rmsSum[channel] / (double)state.tapSamples) : 0.0;
            char peakBuffer[32];
            char rmsBuffer[32];
            printf(" ch%u=peak:%sdB rms:%sdB",
                   channel + 1,
                   DB(state.peak[channel], peakBuffer, sizeof(peakBuffer)),
                   DB(rms, rmsBuffer, sizeof(rmsBuffer)));
        }
        printf("\n");
    }
    return 0;
}
