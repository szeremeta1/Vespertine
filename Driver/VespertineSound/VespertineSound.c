//
// Vespertine: Mac Sound Output (beta): the audio driver.
// SPDX-License-Identifier: GPL-3.0-or-later
//
// A user-space Core Audio driver (an AudioServerPlugIn, loaded by coreaudiod) that shows each speaker group the user
// publishes as an output device of its own, named after the group, with the group's channel layout, a volume and a mute
// that the keyboard's volume keys drive. Behind each output is a hidden capture device of the same channel count on the
// same clock: what other apps play to the output can be read from it. Vespertine's helper reads it and plays it on the
// group's DACs through the speaker-group engine.
//
// The driver does no processing of its own beyond the volume and mute. It never opens another device, never allocates or
// locks on the I/O path except for a short timestamp mutex (as Apple's NullAudio sample does), and publishes nothing
// until Vespertine's helper sets a configuration. A published device disappears again when the helper stops refreshing
// it (it refreshes every few seconds), so a crashed or removed helper never leaves a silent output behind.
//
// Configuration: a custom property on the plug-in object, kVespertineSoundPropertyConfiguration ('vcfg'), holding a
// CFArray of CFDictionaries:
//     uid       CFString   the output's UID (stable across launches: macOS remembers the default output by it)
//     name      CFString   the name shown in the Sound menu (the group's name)
//     channels  CFNumber   1...16
//     labels    CFArray    optional: one AudioChannelLabel (CFNumber) per channel, for the preferred channel layout
//     latency   CFNumber   optional: frames of latency to report, so players keep the picture in sync with the sound
// The capture device's UID is the output's UID followed by ".capture".
//
// Structure after Apple's NullAudio sample driver (Core Audio's "Creating an Audio Server Driver Plug-in"), written for
// any number of devices up to kMaxSlots, each with its own clock, ring buffer, volume and mute.
//

#include <CoreAudio/AudioServerPlugIn.h>
#include <dispatch/dispatch.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "VespertineSoundShared.h"

#pragma mark - Constants

#define kPlugIn_BundleID        VESPERTINE_SOUND_BUNDLE_ID
#define kManufacturerName       "Vespertine"
#define kModelUID               "org.szeremeta.vespertine.sound.model"
#define kCaptureSuffix          ".capture"

enum {
    kMaxSlots = VESPERTINE_SOUND_MAX_DEVICES,
    kMaxChannels = VESPERTINE_SOUND_MAX_CHANNELS,
    kZeroTimeStampPeriod = 16384,
    kRingFrames = kZeroTimeStampPeriod * 4,
    kSafetyOffsetFrames = 32,
    kRefreshTimeoutSeconds = VESPERTINE_SOUND_REFRESH_TIMEOUT_SECONDS,
};

// Object IDs. The plug-in is 1 (kAudioObjectPlugInObject); each slot owns a block of kSlotStride IDs.
enum {
    kSlotBase = 16,
    kSlotStride = 8,
    kSlotOutDevice = 0,
    kSlotOutStream = 1,
    kSlotVolume = 2,
    kSlotMute = 3,
    kSlotCapDevice = 4,
    kSlotCapStream = 5,
};

// Configuration change actions, passed through RequestDeviceConfigurationChange.
enum {
    kChangeChannels = 1,
    kChangeSampleRate = 2,
    kChangeLatency = 3,
};

static const Float64 kSampleRates[] = { 44100.0, 48000.0, 88200.0, 96000.0, 176400.0, 192000.0 };
static const UInt32 kSampleRateCount = sizeof(kSampleRates) / sizeof(kSampleRates[0]);
static const Float32 kVolumeMinDB = -64.0f;
static const Float32 kVolumeMaxDB = 0.0f;

#pragma mark - State

typedef struct {
    // Published state, guarded by gStateMutex.
    bool active;
    bool everUsed;
    CFStringRef uid;
    CFStringRef captureUID;
    CFStringRef name;
    CFStringRef captureName;
    UInt32 channels;
    UInt32 pendingChannels;
    AudioChannelLabel labels[kMaxChannels];
    UInt32 latencyFrames;
    UInt32 pendingLatencyFrames;
    Float64 sampleRate;
    Float64 pendingSampleRate;
    UInt64 lastRefresh;
    bool outStreamActive;
    bool capStreamActive;

    // Volume, read on the I/O thread.
    _Atomic(Float32) volumeScalar;
    _Atomic(bool) mute;

    // Clock, guarded by ioMutex.
    pthread_mutex_t ioMutex;
    UInt32 ioClients;
    Float64 hostTicksPerFrame;
    UInt64 anchorHostTime;
    UInt64 numberTimeStamps;
    UInt64 timestampSeed;

    // Audio, kRingFrames frames of kMaxChannels Float32 samples, allocated once when the slot is first used.
    Float32 *ring;
} Slot;

static pthread_mutex_t gStateMutex = PTHREAD_MUTEX_INITIALIZER;
static UInt32 gRefCount = 0;
static AudioServerPlugInHostRef gHost = NULL;
static Slot gSlots[kMaxSlots];
static Float64 gHostClockFrequency = 0;
static dispatch_source_t gRefreshTimer = NULL;

#pragma mark - Object IDs

static inline AudioObjectID SlotObject(UInt32 slot, UInt32 kind) { return kSlotBase + slot * kSlotStride + kind; }

// Returns true and the slot and kind for one of a slot's objects (active or not).
static bool DecodeObject(AudioObjectID objectID, UInt32 *outSlot, UInt32 *outKind) {
    if (objectID < kSlotBase) return false;
    UInt32 offset = objectID - kSlotBase;
    UInt32 slot = offset / kSlotStride;
    UInt32 kind = offset % kSlotStride;
    if (slot >= kMaxSlots || kind > kSlotCapStream) return false;
    *outSlot = slot;
    *outKind = kind;
    return true;
}

static bool ActiveObject(AudioObjectID objectID, UInt32 *outSlot, UInt32 *outKind) {
    return DecodeObject(objectID, outSlot, outKind) && gSlots[*outSlot].active;
}

#pragma mark - Small helpers

#define CHECK_SIZE(type) do { if (inDataSize < sizeof(type)) return kAudioHardwareBadPropertySizeError; } while (0)
#define RETURN_VALUE(type, value) do { CHECK_SIZE(type); *((type *)outData) = (value); *outDataSize = sizeof(type); return noErr; } while (0)
#define RETURN_CFSTRING(value) do { CHECK_SIZE(CFStringRef); CFStringRef _s = (value); if (_s) CFRetain(_s); *((CFStringRef *)outData) = _s; *outDataSize = sizeof(CFStringRef); return noErr; } while (0)

static inline Float32 ScalarToDB(Float32 scalar) {
    if (scalar <= 0) return kVolumeMinDB;
    if (scalar >= 1) return kVolumeMaxDB;
    return kVolumeMinDB + (kVolumeMaxDB - kVolumeMinDB) * scalar;
}

static inline Float32 DBToScalar(Float32 db) {
    if (db <= kVolumeMinDB) return 0;
    if (db >= kVolumeMaxDB) return 1;
    return (db - kVolumeMinDB) / (kVolumeMaxDB - kVolumeMinDB);
}

static inline Float32 SlotGain(Slot *slot) {
    if (atomic_load_explicit(&slot->mute, memory_order_relaxed)) return 0;
    Float32 scalar = atomic_load_explicit(&slot->volumeScalar, memory_order_relaxed);
    if (scalar <= 0) return 0;
    if (scalar >= 1) return 1;
    return powf(10.0f, ScalarToDB(scalar) / 20.0f);
}

static bool IsSupportedRate(Float64 rate) {
    for (UInt32 i = 0; i < kSampleRateCount; i++) if (kSampleRates[i] == rate) return true;
    return false;
}

static void FillFormat(AudioStreamBasicDescription *format, Float64 rate, UInt32 channels) {
    memset(format, 0, sizeof(*format));
    format->mSampleRate = rate;
    format->mFormatID = kAudioFormatLinearPCM;
    format->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    format->mBytesPerPacket = 4 * channels;
    format->mFramesPerPacket = 1;
    format->mBytesPerFrame = 4 * channels;
    format->mChannelsPerFrame = channels;
    format->mBitsPerChannel = 32;
}

static void SetHostTicksPerFrame(Slot *slot) {
    slot->hostTicksPerFrame = gHostClockFrequency / slot->sampleRate;
}

static void Notify(AudioObjectID objectID, UInt32 count, const AudioObjectPropertyAddress *addresses) {
    if (gHost && count > 0) gHost->PropertiesChanged(gHost, objectID, count, addresses);
}

static void NotifyDeviceList(void) {
    AudioObjectPropertyAddress addresses[2] = {
        { kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        { kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    };
    Notify(kAudioObjectPlugInObject, 2, addresses);
}

static void ReplaceString(CFStringRef *slot, CFStringRef value) {
    if (*slot == value) return;
    if (*slot) CFRelease(*slot);
    *slot = value ? CFRetain(value) : NULL;
}

// The devices the plug-in owns, in object order: each active slot's output, then its capture device.
static UInt32 ActiveDevices(AudioObjectID *outIDs, UInt32 capacity) {
    UInt32 count = 0;
    for (UInt32 s = 0; s < kMaxSlots; s++) {
        if (!gSlots[s].active) continue;
        if (outIDs && count < capacity) outIDs[count] = SlotObject(s, kSlotOutDevice);
        count++;
        if (outIDs && count < capacity) outIDs[count] = SlotObject(s, kSlotCapDevice);
        count++;
    }
    return count;
}

#pragma mark - Configuration

static UInt32 ReadUInt32(CFDictionaryRef dict, CFStringRef key, UInt32 fallback) {
    CFTypeRef value = CFDictionaryGetValue(dict, key);
    if (!value || CFGetTypeID(value) != CFNumberGetTypeID()) return fallback;
    SInt64 number = 0;
    if (!CFNumberGetValue((CFNumberRef)value, kCFNumberSInt64Type, &number) || number < 0 || number > UINT32_MAX) return fallback;
    return (UInt32)number;
}

static CFStringRef ReadString(CFDictionaryRef dict, CFStringRef key) {
    CFTypeRef value = CFDictionaryGetValue(dict, key);
    if (!value || CFGetTypeID(value) != CFStringGetTypeID()) return NULL;
    return (CFStringRef)value;
}

static void DefaultLabels(UInt32 channels, AudioChannelLabel *labels) {
    VespertineSoundDefaultLabels(channels, labels);
}

typedef struct {
    UInt32 objectID;
    UInt64 action;
} PendingChange;

// Applies a new configuration (a CFArray of CFDictionaries, see the header comment). Called with gStateMutex held. Fills
// the notifications and configuration change requests to send once the mutex is released.
static OSStatus ApplyConfiguration(CFArrayRef config, bool *outListChanged,
                                   AudioObjectID *outRenamed, UInt32 *outRenamedCount,
                                   PendingChange *outChanges, UInt32 *outChangeCount,
                                   AudioObjectID *outLayoutChanged, UInt32 *outLayoutChangedCount) {
    CFIndex count = CFArrayGetCount(config);
    if (count > kMaxSlots) return kAudioHardwareIllegalOperationError;

    // Validate everything first, so a bad entry changes nothing.
    for (CFIndex i = 0; i < count; i++) {
        CFTypeRef item = CFArrayGetValueAtIndex(config, i);
        if (!item || CFGetTypeID(item) != CFDictionaryGetTypeID()) return kAudioHardwareIllegalOperationError;
        CFDictionaryRef dict = (CFDictionaryRef)item;
        CFStringRef uid = ReadString(dict, CFSTR("uid"));
        CFStringRef name = ReadString(dict, CFSTR("name"));
        UInt32 channels = ReadUInt32(dict, CFSTR("channels"), 0);
        if (!uid || CFStringGetLength(uid) == 0 || CFStringGetLength(uid) > 200) return kAudioHardwareIllegalOperationError;
        if (!name || CFStringGetLength(name) == 0) return kAudioHardwareIllegalOperationError;
        if (channels < 1 || channels > kMaxChannels) return kAudioHardwareIllegalOperationError;
        for (CFIndex j = 0; j < i; j++) {
            CFStringRef other = ReadString((CFDictionaryRef)CFArrayGetValueAtIndex(config, j), CFSTR("uid"));
            if (other && CFStringCompare(uid, other, 0) == kCFCompareEqualTo) return kAudioHardwareIllegalOperationError;
        }
    }

    UInt64 now = mach_absolute_time();
    bool wanted[kMaxSlots] = { false };
    *outListChanged = false;

    for (CFIndex i = 0; i < count; i++) {
        CFDictionaryRef dict = (CFDictionaryRef)CFArrayGetValueAtIndex(config, i);
        CFStringRef uid = ReadString(dict, CFSTR("uid"));
        CFStringRef name = ReadString(dict, CFSTR("name"));
        UInt32 channels = ReadUInt32(dict, CFSTR("channels"), 2);
        UInt32 latency = ReadUInt32(dict, CFSTR("latency"), 0);
        if (latency > 96000) latency = 96000;

        AudioChannelLabel labels[kMaxChannels];
        DefaultLabels(channels, labels);
        CFTypeRef labelArray = CFDictionaryGetValue(dict, CFSTR("labels"));
        if (labelArray && CFGetTypeID(labelArray) == CFArrayGetTypeID() && CFArrayGetCount((CFArrayRef)labelArray) == (CFIndex)channels) {
            for (UInt32 c = 0; c < channels; c++) {
                CFTypeRef n = CFArrayGetValueAtIndex((CFArrayRef)labelArray, c);
                SInt64 label = 0;
                if (n && CFGetTypeID(n) == CFNumberGetTypeID() && CFNumberGetValue((CFNumberRef)n, kCFNumberSInt64Type, &label) && label >= 0 && label <= UINT32_MAX) {
                    labels[c] = (AudioChannelLabel)label;
                }
            }
        }

        // The slot already showing this UID, else a slot never used, else any free slot.
        int found = -1;
        for (UInt32 s = 0; s < kMaxSlots && found < 0; s++) {
            if (gSlots[s].uid && CFStringCompare(gSlots[s].uid, uid, 0) == kCFCompareEqualTo) found = (int)s;
        }
        for (UInt32 s = 0; s < kMaxSlots && found < 0; s++) if (!gSlots[s].active && !gSlots[s].everUsed) found = (int)s;
        for (UInt32 s = 0; s < kMaxSlots && found < 0; s++) if (!gSlots[s].active && !wanted[s]) found = (int)s;
        if (found < 0) return kAudioHardwareIllegalOperationError;

        Slot *slot = &gSlots[found];
        wanted[found] = true;
        slot->lastRefresh = now;

        if (!slot->ring) {
            slot->ring = calloc((size_t)kRingFrames * kMaxChannels, sizeof(Float32));
            if (!slot->ring) return kAudioHardwareUnspecifiedError;
        }

        if (!slot->active) {
            // A new device: everything can be set directly, nobody is using it yet.
            ReplaceString(&slot->uid, uid);
            CFStringRef captureUID = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@" kCaptureSuffix), uid);
            ReplaceString(&slot->captureUID, captureUID);
            if (captureUID) CFRelease(captureUID);
            ReplaceString(&slot->name, name);
            CFStringRef captureName = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@ (Vespertine capture)"), name);
            ReplaceString(&slot->captureName, captureName);
            if (captureName) CFRelease(captureName);
            slot->channels = channels;
            slot->pendingChannels = channels;
            memcpy(slot->labels, labels, sizeof(labels));
            slot->latencyFrames = latency;
            slot->pendingLatencyFrames = latency;
            if (slot->sampleRate == 0) slot->sampleRate = 48000.0;
            slot->pendingSampleRate = slot->sampleRate;
            if (!slot->everUsed) {
                atomic_store(&slot->volumeScalar, 1.0f);
                atomic_store(&slot->mute, false);
            }
            slot->outStreamActive = true;
            slot->capStreamActive = true;
            slot->ioClients = 0;
            slot->timestampSeed++;
            SetHostTicksPerFrame(slot);
            memset(slot->ring, 0, (size_t)kRingFrames * kMaxChannels * sizeof(Float32));
            slot->active = true;
            slot->everUsed = true;
            *outListChanged = true;
            continue;
        }

        // An existing device: a new name is a property change; a new channel count or latency is a configuration change
        // the host schedules when it's safe.
        if (CFStringCompare(slot->name, name, 0) != kCFCompareEqualTo) {
            ReplaceString(&slot->name, name);
            CFStringRef captureName = CFStringCreateWithFormat(NULL, NULL, CFSTR("%@ (Vespertine capture)"), name);
            ReplaceString(&slot->captureName, captureName);
            if (captureName) CFRelease(captureName);
            outRenamed[(*outRenamedCount)++] = SlotObject((UInt32)found, kSlotOutDevice);
        }
        if (memcmp(slot->labels, labels, sizeof(labels)) != 0 && channels == slot->channels) {
            memcpy(slot->labels, labels, sizeof(labels));
            outLayoutChanged[(*outLayoutChangedCount)++] = SlotObject((UInt32)found, kSlotOutDevice);
            outLayoutChanged[(*outLayoutChangedCount)++] = SlotObject((UInt32)found, kSlotCapDevice);
        }
        if (channels != slot->channels && channels != slot->pendingChannels) {
            slot->pendingChannels = channels;
            memcpy(slot->labels, labels, sizeof(labels));
            outChanges[(*outChangeCount)++] = (PendingChange){ SlotObject((UInt32)found, kSlotOutDevice), kChangeChannels };
            outChanges[(*outChangeCount)++] = (PendingChange){ SlotObject((UInt32)found, kSlotCapDevice), kChangeChannels };
        }
        if (latency != slot->latencyFrames && latency != slot->pendingLatencyFrames) {
            slot->pendingLatencyFrames = latency;
            outChanges[(*outChangeCount)++] = (PendingChange){ SlotObject((UInt32)found, kSlotOutDevice), kChangeLatency };
        }
    }

    for (UInt32 s = 0; s < kMaxSlots; s++) {
        if (gSlots[s].active && !wanted[s]) {
            gSlots[s].active = false;
            *outListChanged = true;
        }
    }
    return noErr;
}

static CFArrayRef CopyConfiguration(void) {
    CFMutableArrayRef array = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    for (UInt32 s = 0; s < kMaxSlots; s++) {
        Slot *slot = &gSlots[s];
        if (!slot->active) continue;
        CFMutableDictionaryRef dict = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        CFDictionarySetValue(dict, CFSTR("uid"), slot->uid);
        CFDictionarySetValue(dict, CFSTR("name"), slot->name);
        SInt64 channels = slot->channels, latency = slot->latencyFrames;
        CFNumberRef n1 = CFNumberCreate(NULL, kCFNumberSInt64Type, &channels);
        CFNumberRef n2 = CFNumberCreate(NULL, kCFNumberSInt64Type, &latency);
        CFDictionarySetValue(dict, CFSTR("channels"), n1);
        CFDictionarySetValue(dict, CFSTR("latency"), n2);
        CFRelease(n1);
        CFRelease(n2);
        CFMutableArrayRef labels = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
        for (UInt32 c = 0; c < slot->channels; c++) {
            SInt64 label = slot->labels[c];
            CFNumberRef n = CFNumberCreate(NULL, kCFNumberSInt64Type, &label);
            CFArrayAppendValue(labels, n);
            CFRelease(n);
        }
        CFDictionarySetValue(dict, CFSTR("labels"), labels);
        CFRelease(labels);
        CFArrayAppendValue(array, dict);
        CFRelease(dict);
    }
    return array;
}

// Runs every few seconds: a device the helper has stopped refreshing is taken away, so sound never goes into a device
// that nothing carries to the speakers.
static void ExpireStaleDevices(void) {
    UInt64 now = mach_absolute_time();
    UInt64 limit = (UInt64)(gHostClockFrequency * (Float64)kRefreshTimeoutSeconds);
    bool changed = false;
    pthread_mutex_lock(&gStateMutex);
    for (UInt32 s = 0; s < kMaxSlots; s++) {
        if (gSlots[s].active && now - gSlots[s].lastRefresh > limit) {
            gSlots[s].active = false;
            changed = true;
        }
    }
    pthread_mutex_unlock(&gStateMutex);
    if (changed) NotifyDeviceList();
}

#pragma mark - Plug-in interface

static HRESULT QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface);
static ULONG AddRef(void *inDriver);
static ULONG Release(void *inDriver);
static OSStatus Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID);
static OSStatus DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo);
static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo);
static Boolean HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress);
static OSStatus IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable);
static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize);
static OSStatus GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData);
static OSStatus SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData);
static OSStatus StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed);
static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace);
static OSStatus BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);
static OSStatus DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer);
static OSStatus EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    QueryInterface,
    AddRef,
    Release,
    Initialize,
    CreateDevice,
    DestroyDevice,
    AddDeviceClient,
    RemoveDeviceClient,
    PerformDeviceConfigurationChange,
    AbortDeviceConfigurationChange,
    HasProperty,
    IsPropertySettable,
    GetPropertyDataSize,
    GetPropertyData,
    SetPropertyData,
    StartIO,
    StopIO,
    GetZeroTimeStamp,
    WillDoIOOperation,
    BeginIOOperation,
    DoIOOperation,
    EndIOOperation,
};
static AudioServerPlugInDriverInterface *gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

// The factory named in Info.plist's CFPlugInFactories.
void *VespertineSound_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
void *VespertineSound_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) return gDriverRef;
    return NULL;
}

static HRESULT QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    if (inDriver != gDriverRef || !outInterface) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (!requested) return kAudioHardwareIllegalOperationError;
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        pthread_mutex_lock(&gStateMutex);
        gRefCount++;
        pthread_mutex_unlock(&gStateMutex);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG AddRef(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount < UINT32_MAX) gRefCount++;
    ULONG count = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

static ULONG Release(void *inDriver) {
    if (inDriver != gDriverRef) return 0;
    pthread_mutex_lock(&gStateMutex);
    if (gRefCount > 0) gRefCount--;
    ULONG count = gRefCount;
    pthread_mutex_unlock(&gStateMutex);
    return count;
}

static OSStatus Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gHost = inHost;

    struct mach_timebase_info timebase;
    mach_timebase_info(&timebase);
    gHostClockFrequency = (Float64)timebase.denom / (Float64)timebase.numer * 1000000000.0;

    for (UInt32 s = 0; s < kMaxSlots; s++) {
        memset(&gSlots[s], 0, sizeof(Slot));
        pthread_mutex_init(&gSlots[s].ioMutex, NULL);
        gSlots[s].sampleRate = 48000.0;
        gSlots[s].pendingSampleRate = 48000.0;
        atomic_init(&gSlots[s].volumeScalar, 1.0f);
        atomic_init(&gSlots[s].mute, false);
    }

    dispatch_queue_t queue = dispatch_queue_create("org.szeremeta.vespertine.sound.refresh", DISPATCH_QUEUE_SERIAL);
    gRefreshTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(gRefreshTimer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), 5 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(gRefreshTimer, ^{ ExpireStaleDevices(); });
    dispatch_resume(gRefreshTimer);
    return noErr;
}

static OSStatus CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID) {
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inClientInfo;
    UInt32 s, kind;
    if (inDriver != gDriverRef || !DecodeObject(inDeviceObjectID, &s, &kind)) return kAudioHardwareBadObjectError;
    return noErr;
}

static OSStatus RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inClientInfo;
    UInt32 s, kind;
    if (inDriver != gDriverRef || !DecodeObject(inDeviceObjectID, &s, &kind)) return kAudioHardwareBadObjectError;
    return noErr;
}

static OSStatus PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
    (void)inChangeInfo;
    UInt32 s, kind;
    if (inDriver != gDriverRef || !DecodeObject(inDeviceObjectID, &s, &kind)) return kAudioHardwareBadObjectError;
    Slot *slot = &gSlots[s];
    pthread_mutex_lock(&gStateMutex);
    pthread_mutex_lock(&slot->ioMutex);
    switch (inChangeAction) {
        case kChangeChannels:
            slot->channels = slot->pendingChannels;
            memset(slot->ring, 0, (size_t)kRingFrames * kMaxChannels * sizeof(Float32));
            break;
        case kChangeSampleRate:
            slot->sampleRate = slot->pendingSampleRate;
            SetHostTicksPerFrame(slot);
            slot->timestampSeed++;
            memset(slot->ring, 0, (size_t)kRingFrames * kMaxChannels * sizeof(Float32));
            break;
        case kChangeLatency:
            slot->latencyFrames = slot->pendingLatencyFrames;
            break;
        default:
            break;
    }
    pthread_mutex_unlock(&slot->ioMutex);
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

static OSStatus AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void *inChangeInfo) {
    (void)inChangeAction; (void)inChangeInfo;
    UInt32 s, kind;
    if (inDriver != gDriverRef || !DecodeObject(inDeviceObjectID, &s, &kind)) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    gSlots[s].pendingChannels = gSlots[s].channels;
    gSlots[s].pendingSampleRate = gSlots[s].sampleRate;
    gSlots[s].pendingLatencyFrames = gSlots[s].latencyFrames;
    pthread_mutex_unlock(&gStateMutex);
    return noErr;
}

#pragma mark - Properties

// One function answers every property: with outData NULL it only works out the size. Called with gStateMutex held.
static OSStatus PropertyData(AudioObjectID objectID, const AudioObjectPropertyAddress *address,
                             UInt32 qualifierSize, const void *qualifier,
                             UInt32 inDataSize, UInt32 *outDataSize, void *outData, bool sizeOnly);

static Boolean HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef || !inAddress) return false;
    UInt32 size = 0;
    pthread_mutex_lock(&gStateMutex);
    OSStatus status = PropertyData(inObjectID, inAddress, 0, NULL, 0, &size, NULL, true);
    pthread_mutex_unlock(&gStateMutex);
    return status == noErr;
}

static OSStatus IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef || !inAddress || !outIsSettable) return kAudioHardwareBadObjectError;
    if (!HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) return kAudioHardwareUnknownPropertyError;
    UInt32 s, kind;
    bool settable = false;
    if (inObjectID == kAudioObjectPlugInObject) {
        settable = inAddress->mSelector == kVespertineSoundPropertyConfiguration;
    } else if (DecodeObject(inObjectID, &s, &kind)) {
        switch (kind) {
            case kSlotOutDevice:
            case kSlotCapDevice:
                settable = inAddress->mSelector == kAudioDevicePropertyNominalSampleRate;
                break;
            case kSlotOutStream:
            case kSlotCapStream:
                settable = inAddress->mSelector == kAudioStreamPropertyIsActive
                    || inAddress->mSelector == kAudioStreamPropertyVirtualFormat
                    || inAddress->mSelector == kAudioStreamPropertyPhysicalFormat;
                break;
            case kSlotVolume:
                settable = inAddress->mSelector == kAudioLevelControlPropertyScalarValue
                    || inAddress->mSelector == kAudioLevelControlPropertyDecibelValue;
                break;
            case kSlotMute:
                settable = inAddress->mSelector == kAudioBooleanControlPropertyValue;
                break;
        }
    }
    *outIsSettable = settable;
    return noErr;
}

static OSStatus GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 *outDataSize) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef || !inAddress || !outDataSize) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    OSStatus status = PropertyData(inObjectID, inAddress, inQualifierDataSize, inQualifierData, 0, outDataSize, NULL, true);
    pthread_mutex_unlock(&gStateMutex);
    return status;
}

static OSStatus GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef || !inAddress || !outDataSize || !outData) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateMutex);
    OSStatus status = PropertyData(inObjectID, inAddress, inQualifierDataSize, inQualifierData, inDataSize, outDataSize, outData, false);
    pthread_mutex_unlock(&gStateMutex);
    return status;
}

// Sizes for the size-only pass. Every RETURN_* below checks inDataSize, so for the size pass the caller passes a huge
// size and a scratch buffer: simpler than a second table of sizes.
static OSStatus PlugInProperty(const AudioObjectPropertyAddress *address, UInt32 qualifierSize, const void *qualifier,
                               UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: RETURN_CFSTRING(CFSTR(kManufacturerName));
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: {
            UInt32 capacity = inDataSize / sizeof(AudioObjectID);
            UInt32 written = ActiveDevices((AudioObjectID *)outData, capacity);
            if (written > capacity) written = capacity;
            *outDataSize = written * sizeof(AudioObjectID);
            return noErr;
        }
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            CHECK_SIZE(AudioObjectID);
            if (qualifierSize != sizeof(CFStringRef) || !qualifier) return kAudioHardwareBadPropertySizeError;
            CFStringRef uid = *(const CFStringRef *)qualifier;
            AudioObjectID result = kAudioObjectUnknown;
            for (UInt32 s = 0; s < kMaxSlots && uid; s++) {
                if (!gSlots[s].active) continue;
                if (CFStringCompare(uid, gSlots[s].uid, 0) == kCFCompareEqualTo) result = SlotObject(s, kSlotOutDevice);
                else if (CFStringCompare(uid, gSlots[s].captureUID, 0) == kCFCompareEqualTo) result = SlotObject(s, kSlotCapDevice);
            }
            *(AudioObjectID *)outData = result;
            *outDataSize = sizeof(AudioObjectID);
            return noErr;
        }
        case kAudioPlugInPropertyResourceBundle: RETURN_CFSTRING(CFSTR(""));
        case kAudioObjectPropertyCustomPropertyInfoList: {
            CHECK_SIZE(AudioServerPlugInCustomPropertyInfo);
            AudioServerPlugInCustomPropertyInfo *info = outData;
            info->mSelector = kVespertineSoundPropertyConfiguration;
            info->mPropertyDataType = kAudioServerPlugInCustomPropertyDataTypeCFPropertyList;
            info->mQualifierDataType = kAudioServerPlugInCustomPropertyDataTypeNone;
            *outDataSize = sizeof(AudioServerPlugInCustomPropertyInfo);
            return noErr;
        }
        case kVespertineSoundPropertyConfiguration: {
            CHECK_SIZE(CFPropertyListRef);
            *(CFPropertyListRef *)outData = CopyConfiguration();
            *outDataSize = sizeof(CFPropertyListRef);
            return noErr;
        }
        default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus DeviceProperty(UInt32 s, bool capture, const AudioObjectPropertyAddress *address,
                               UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    Slot *slot = &gSlots[s];
    AudioObjectID self = SlotObject(s, capture ? kSlotCapDevice : kSlotOutDevice);
    AudioObjectPropertyScope scope = address->mScope;
    bool ownScope = capture ? scope == kAudioObjectPropertyScopeInput : scope == kAudioObjectPropertyScopeOutput;
    bool anyScope = scope == kAudioObjectPropertyScopeGlobal || ownScope;

    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, kAudioObjectPlugInObject);
        case kAudioObjectPropertyName: RETURN_CFSTRING(capture ? slot->captureName : slot->name);
        case kAudioObjectPropertyManufacturer: RETURN_CFSTRING(CFSTR(kManufacturerName));
        case kAudioObjectPropertyOwnedObjects:
        case kAudioObjectPropertyControlList: {
            AudioObjectID objects[3];
            UInt32 count = 0;
            bool controls = address->mSelector == kAudioObjectPropertyControlList;
            if (!capture) {
                if (!controls && anyScope) objects[count++] = SlotObject(s, kSlotOutStream);
                if (anyScope) { objects[count++] = SlotObject(s, kSlotVolume); objects[count++] = SlotObject(s, kSlotMute); }
            } else if (!controls && anyScope) {
                objects[count++] = SlotObject(s, kSlotCapStream);
            }
            UInt32 capacity = inDataSize / sizeof(AudioObjectID);
            if (count > capacity) count = capacity;
            if (outData) memcpy(outData, objects, count * sizeof(AudioObjectID));
            *outDataSize = count * sizeof(AudioObjectID);
            return noErr;
        }
        case kAudioDevicePropertyStreams: {
            UInt32 count = (scope == kAudioObjectPropertyScopeGlobal || ownScope) ? 1 : 0;
            if (count > inDataSize / sizeof(AudioObjectID)) count = 0;
            if (count && outData) *(AudioObjectID *)outData = SlotObject(s, capture ? kSlotCapStream : kSlotOutStream);
            *outDataSize = count * sizeof(AudioObjectID);
            return noErr;
        }
        case kAudioDevicePropertyDeviceUID: RETURN_CFSTRING(capture ? slot->captureUID : slot->uid);
        case kAudioDevicePropertyModelUID: RETURN_CFSTRING(CFSTR(kModelUID));
        case kAudioDevicePropertyTransportType: RETURN_VALUE(UInt32, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: RETURN_VALUE(AudioObjectID, self);
        case kAudioDevicePropertyClockDomain: RETURN_VALUE(UInt32, 0x56530000u + s);
        case kAudioDevicePropertyDeviceIsAlive: RETURN_VALUE(UInt32, slot->active ? 1 : 0);
        case kAudioDevicePropertyDeviceIsRunning: RETURN_VALUE(UInt32, slot->ioClients > 0 ? 1 : 0);
        case kAudioDevicePropertyDeviceCanBeDefaultDevice: RETURN_VALUE(UInt32, (!capture && ownScope) ? 1 : 0);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: RETURN_VALUE(UInt32, 0);
        case kAudioDevicePropertyIsHidden: RETURN_VALUE(UInt32, capture ? 1 : 0);
        case kAudioDevicePropertyLatency: RETURN_VALUE(UInt32, (!capture && ownScope) ? slot->latencyFrames : 0);
        case kAudioDevicePropertySafetyOffset: RETURN_VALUE(UInt32, kSafetyOffsetFrames);
        case kAudioDevicePropertyNominalSampleRate: RETURN_VALUE(Float64, slot->sampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            UInt32 capacity = inDataSize / sizeof(AudioValueRange);
            UInt32 count = kSampleRateCount < capacity ? kSampleRateCount : capacity;
            if (outData) {
                AudioValueRange *ranges = outData;
                for (UInt32 i = 0; i < count; i++) ranges[i] = (AudioValueRange){ kSampleRates[i], kSampleRates[i] };
            }
            *outDataSize = count * sizeof(AudioValueRange);
            return noErr;
        }
        case kAudioDevicePropertyZeroTimeStampPeriod: RETURN_VALUE(UInt32, kZeroTimeStampPeriod);
        case kAudioDevicePropertyClockIsStable: RETURN_VALUE(UInt32, 1);
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            if (inDataSize < 2 * sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
            UInt32 *pair = outData;
            UInt32 left = 1, right = slot->channels > 1 ? 2 : 1;
            for (UInt32 c = 0; c < slot->channels; c++) {
                if (slot->labels[c] == kAudioChannelLabel_Left) left = c + 1;
                if (slot->labels[c] == kAudioChannelLabel_Right) right = c + 1;
            }
            pair[0] = left;
            pair[1] = right;
            *outDataSize = 2 * sizeof(UInt32);
            return noErr;
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            UInt32 size = (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + slot->channels * sizeof(AudioChannelDescription));
            if (inDataSize < size) return kAudioHardwareBadPropertySizeError;
            AudioChannelLayout *layout = outData;
            memset(layout, 0, size);
            layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            layout->mNumberChannelDescriptions = slot->channels;
            for (UInt32 c = 0; c < slot->channels; c++) layout->mChannelDescriptions[c].mChannelLabel = slot->labels[c];
            *outDataSize = size;
            return noErr;
        }
        default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus StreamProperty(UInt32 s, bool capture, const AudioObjectPropertyAddress *address,
                               UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    Slot *slot = &gSlots[s];
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, kAudioObjectClassID);
        case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, kAudioStreamClassID);
        case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, SlotObject(s, capture ? kSlotCapDevice : kSlotOutDevice));
        case kAudioObjectPropertyOwnedObjects: *outDataSize = 0; return noErr;
        case kAudioStreamPropertyIsActive: RETURN_VALUE(UInt32, (capture ? slot->capStreamActive : slot->outStreamActive) ? 1 : 0);
        case kAudioStreamPropertyDirection: RETURN_VALUE(UInt32, capture ? 1 : 0);
        case kAudioStreamPropertyTerminalType: RETURN_VALUE(UInt32, capture ? kAudioStreamTerminalTypeLine : kAudioStreamTerminalTypeSpeaker);
        case kAudioStreamPropertyStartingChannel: RETURN_VALUE(UInt32, 1);
        case kAudioStreamPropertyLatency: RETURN_VALUE(UInt32, 0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat: {
            CHECK_SIZE(AudioStreamBasicDescription);
            if (outData) FillFormat(outData, slot->sampleRate, slot->channels);
            *outDataSize = sizeof(AudioStreamBasicDescription);
            return noErr;
        }
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            UInt32 capacity = inDataSize / sizeof(AudioStreamRangedDescription);
            UInt32 count = kSampleRateCount < capacity ? kSampleRateCount : capacity;
            if (outData) {
                AudioStreamRangedDescription *formats = outData;
                for (UInt32 i = 0; i < count; i++) {
                    FillFormat(&formats[i].mFormat, kSampleRates[i], slot->channels);
                    formats[i].mSampleRateRange = (AudioValueRange){ kSampleRates[i], kSampleRates[i] };
                }
            }
            *outDataSize = count * sizeof(AudioStreamRangedDescription);
            return noErr;
        }
        default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus ControlProperty(UInt32 s, bool mute, const AudioObjectPropertyAddress *address,
                                UInt32 qualifierSize, const void *qualifier,
                                UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    (void)qualifierSize; (void)qualifier;
    Slot *slot = &gSlots[s];
    switch (address->mSelector) {
        case kAudioObjectPropertyBaseClass: RETURN_VALUE(AudioClassID, mute ? kAudioBooleanControlClassID : kAudioLevelControlClassID);
        case kAudioObjectPropertyClass: RETURN_VALUE(AudioClassID, mute ? kAudioMuteControlClassID : kAudioVolumeControlClassID);
        case kAudioObjectPropertyOwner: RETURN_VALUE(AudioObjectID, SlotObject(s, kSlotOutDevice));
        case kAudioObjectPropertyOwnedObjects: *outDataSize = 0; return noErr;
        case kAudioControlPropertyScope: RETURN_VALUE(AudioObjectPropertyScope, kAudioObjectPropertyScopeOutput);
        case kAudioControlPropertyElement: RETURN_VALUE(AudioObjectPropertyElement, kAudioObjectPropertyElementMain);
        default: break;
    }
    if (mute) {
        if (address->mSelector == kAudioBooleanControlPropertyValue) RETURN_VALUE(UInt32, atomic_load(&slot->mute) ? 1 : 0);
        return kAudioHardwareUnknownPropertyError;
    }
    switch (address->mSelector) {
        case kAudioLevelControlPropertyScalarValue: RETURN_VALUE(Float32, atomic_load(&slot->volumeScalar));
        case kAudioLevelControlPropertyDecibelValue: RETURN_VALUE(Float32, ScalarToDB(atomic_load(&slot->volumeScalar)));
        case kAudioLevelControlPropertyDecibelRange: RETURN_VALUE(AudioValueRange, ((AudioValueRange){ kVolumeMinDB, kVolumeMaxDB }));
        case kAudioLevelControlPropertyConvertScalarToDecibels: {
            CHECK_SIZE(Float32);
            if (outData) *(Float32 *)outData = ScalarToDB(*(Float32 *)outData);
            *outDataSize = sizeof(Float32);
            return noErr;
        }
        case kAudioLevelControlPropertyConvertDecibelsToScalar: {
            CHECK_SIZE(Float32);
            if (outData) *(Float32 *)outData = DBToScalar(*(Float32 *)outData);
            *outDataSize = sizeof(Float32);
            return noErr;
        }
        default: return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus PropertyData(AudioObjectID objectID, const AudioObjectPropertyAddress *address,
                             UInt32 qualifierSize, const void *qualifier,
                             UInt32 inDataSize, UInt32 *outDataSize, void *outData, bool sizeOnly) {
    // The size pass runs the same code into a scratch buffer big enough for any answer here.
    union { char bytes[sizeof(AudioStreamRangedDescription) * 8 + 4096]; double align; } scratch;
    Float32 convertIn = 0;
    if (sizeOnly) {
        outData = scratch.bytes;
        inDataSize = sizeof(scratch.bytes);
        if (address->mSelector == kAudioLevelControlPropertyConvertScalarToDecibels
            || address->mSelector == kAudioLevelControlPropertyConvertDecibelsToScalar) {
            memcpy(scratch.bytes, &convertIn, sizeof(convertIn));
        }
    }

    OSStatus status;
    UInt32 s, kind;
    if (objectID == kAudioObjectPlugInObject) {
        status = PlugInProperty(address, qualifierSize, qualifier, inDataSize, outDataSize, outData);
    } else if (ActiveObject(objectID, &s, &kind)) {
        switch (kind) {
            case kSlotOutDevice: status = DeviceProperty(s, false, address, inDataSize, outDataSize, outData); break;
            case kSlotCapDevice: status = DeviceProperty(s, true, address, inDataSize, outDataSize, outData); break;
            case kSlotOutStream: status = StreamProperty(s, false, address, inDataSize, outDataSize, outData); break;
            case kSlotCapStream: status = StreamProperty(s, true, address, inDataSize, outDataSize, outData); break;
            case kSlotVolume: status = ControlProperty(s, false, address, qualifierSize, qualifier, inDataSize, outDataSize, outData); break;
            case kSlotMute: status = ControlProperty(s, true, address, qualifierSize, qualifier, inDataSize, outDataSize, outData); break;
            default: status = kAudioHardwareBadObjectError; break;
        }
    } else {
        status = kAudioHardwareBadObjectError;
    }

    // The size pass must not leak what it built.
    if (sizeOnly && status == noErr) {
        bool cfString = false;
        switch (address->mSelector) {
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyManufacturer:
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:
            case kAudioPlugInPropertyResourceBundle:
                cfString = true;
                break;
            case kVespertineSoundPropertyConfiguration: {
                CFPropertyListRef list = *(CFPropertyListRef *)scratch.bytes;
                if (list) CFRelease(list);
                break;
            }
            default: break;
        }
        if (cfString) {
            CFStringRef string = *(CFStringRef *)scratch.bytes;
            if (string) CFRelease(string);
        }
    }
    return status;
}

static OSStatus SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize, const void *inQualifierData, UInt32 inDataSize, const void *inData) {
    (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gDriverRef || !inAddress || !inData) return kAudioHardwareBadObjectError;

    AudioObjectPropertyAddress changed[4];
    UInt32 changedCount = 0;
    AudioObjectID changedObject = inObjectID;
    PendingChange requests[kMaxSlots * 3 + 2];
    UInt32 requestCount = 0;
    AudioObjectID renamed[kMaxSlots];
    UInt32 renamedCount = 0;
    AudioObjectID layoutChanged[kMaxSlots * 2];
    UInt32 layoutChangedCount = 0;
    bool listChanged = false;
    OSStatus status = noErr;

    pthread_mutex_lock(&gStateMutex);
    UInt32 s, kind;
    if (inObjectID == kAudioObjectPlugInObject) {
        if (inAddress->mSelector != kVespertineSoundPropertyConfiguration) { status = kAudioHardwareUnknownPropertyError; goto done; }
        if (inDataSize < sizeof(CFPropertyListRef)) { status = kAudioHardwareBadPropertySizeError; goto done; }
        CFPropertyListRef list = *(const CFPropertyListRef *)inData;
        if (!list || CFGetTypeID(list) != CFArrayGetTypeID()) { status = kAudioHardwareIllegalOperationError; goto done; }
        status = ApplyConfiguration((CFArrayRef)list, &listChanged, renamed, &renamedCount, requests, &requestCount, layoutChanged, &layoutChangedCount);
    } else if (ActiveObject(inObjectID, &s, &kind)) {
        Slot *slot = &gSlots[s];
        switch (kind) {
            case kSlotOutDevice:
            case kSlotCapDevice:
            case kSlotOutStream:
            case kSlotCapStream: {
                Float64 rate = 0;
                if (inAddress->mSelector == kAudioDevicePropertyNominalSampleRate && (kind == kSlotOutDevice || kind == kSlotCapDevice)) {
                    if (inDataSize < sizeof(Float64)) { status = kAudioHardwareBadPropertySizeError; break; }
                    rate = *(const Float64 *)inData;
                } else if ((inAddress->mSelector == kAudioStreamPropertyVirtualFormat || inAddress->mSelector == kAudioStreamPropertyPhysicalFormat)
                           && (kind == kSlotOutStream || kind == kSlotCapStream)) {
                    if (inDataSize < sizeof(AudioStreamBasicDescription)) { status = kAudioHardwareBadPropertySizeError; break; }
                    const AudioStreamBasicDescription *format = inData;
                    if (format->mFormatID != kAudioFormatLinearPCM || format->mChannelsPerFrame != slot->channels
                        || format->mBitsPerChannel != 32 || !(format->mFormatFlags & kAudioFormatFlagIsFloat)) {
                        status = kAudioDeviceUnsupportedFormatError;
                        break;
                    }
                    rate = format->mSampleRate;
                } else if (inAddress->mSelector == kAudioStreamPropertyIsActive && (kind == kSlotOutStream || kind == kSlotCapStream)) {
                    if (inDataSize < sizeof(UInt32)) { status = kAudioHardwareBadPropertySizeError; break; }
                    bool active = *(const UInt32 *)inData != 0;
                    bool *field = kind == kSlotOutStream ? &slot->outStreamActive : &slot->capStreamActive;
                    if (*field != active) {
                        *field = active;
                        changed[changedCount++] = (AudioObjectPropertyAddress){ kAudioStreamPropertyIsActive, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
                    }
                    break;
                } else {
                    status = kAudioHardwareUnknownPropertyError;
                    break;
                }
                if (!IsSupportedRate(rate)) { status = kAudioHardwareIllegalOperationError; break; }
                if (rate != slot->sampleRate && rate != slot->pendingSampleRate) {
                    // Both devices of a slot share one clock, so both change.
                    slot->pendingSampleRate = rate;
                    requests[requestCount++] = (PendingChange){ SlotObject(s, kSlotOutDevice), kChangeSampleRate };
                    requests[requestCount++] = (PendingChange){ SlotObject(s, kSlotCapDevice), kChangeSampleRate };
                }
                break;
            }
            case kSlotVolume: {
                if (inDataSize < sizeof(Float32)) { status = kAudioHardwareBadPropertySizeError; break; }
                Float32 value = *(const Float32 *)inData;
                Float32 scalar;
                if (inAddress->mSelector == kAudioLevelControlPropertyScalarValue) scalar = value;
                else if (inAddress->mSelector == kAudioLevelControlPropertyDecibelValue) scalar = DBToScalar(value);
                else { status = kAudioHardwareUnknownPropertyError; break; }
                if (scalar < 0) scalar = 0;
                if (scalar > 1) scalar = 1;
                if (scalar != atomic_load(&slot->volumeScalar)) {
                    atomic_store(&slot->volumeScalar, scalar);
                    changed[changedCount++] = (AudioObjectPropertyAddress){ kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
                    changed[changedCount++] = (AudioObjectPropertyAddress){ kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
                }
                break;
            }
            case kSlotMute: {
                if (inAddress->mSelector != kAudioBooleanControlPropertyValue) { status = kAudioHardwareUnknownPropertyError; break; }
                if (inDataSize < sizeof(UInt32)) { status = kAudioHardwareBadPropertySizeError; break; }
                bool value = *(const UInt32 *)inData != 0;
                if (value != atomic_load(&slot->mute)) {
                    atomic_store(&slot->mute, value);
                    changed[changedCount++] = (AudioObjectPropertyAddress){ kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
                }
                break;
            }
        }
    } else {
        status = kAudioHardwareBadObjectError;
    }
done:
    pthread_mutex_unlock(&gStateMutex);

    // Tell the host only after the state is released: it may call straight back in.
    if (status == noErr) {
        if (listChanged) NotifyDeviceList();
        for (UInt32 i = 0; i < renamedCount; i++) {
            AudioObjectPropertyAddress name = { kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
            Notify(renamed[i], 1, &name);
            Notify(renamed[i] + (kSlotCapDevice - kSlotOutDevice), 1, &name);
        }
        for (UInt32 i = 0; i < layoutChangedCount; i++) {
            AudioObjectPropertyAddress layout[2] = {
                { kAudioDevicePropertyPreferredChannelLayout, kAudioObjectPropertyScopeWildcard, kAudioObjectPropertyElementMain },
                { kAudioDevicePropertyPreferredChannelsForStereo, kAudioObjectPropertyScopeWildcard, kAudioObjectPropertyElementMain },
            };
            Notify(layoutChanged[i], 2, layout);
        }
        Notify(changedObject, changedCount, changed);
        for (UInt32 i = 0; i < requestCount; i++) {
            if (gHost) gHost->RequestDeviceConfigurationChange(gHost, requests[i].objectID, requests[i].action, NULL);
        }
    }
    return status;
}

#pragma mark - I/O

static OSStatus StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    UInt32 s, kind;
    if (inDriver != gDriverRef || !ActiveObject(inDeviceObjectID, &s, &kind)) return kAudioHardwareBadObjectError;
    Slot *slot = &gSlots[s];
    pthread_mutex_lock(&slot->ioMutex);
    if (slot->ioClients == UINT32_MAX) {
        pthread_mutex_unlock(&slot->ioMutex);
        return kAudioHardwareIllegalOperationError;
    }
    if (slot->ioClients == 0) {
        // The first client on either device starts the slot's clock; the other device joins it.
        slot->numberTimeStamps = 0;
        slot->anchorHostTime = mach_absolute_time();
        SetHostTicksPerFrame(slot);
        memset(slot->ring, 0, (size_t)kRingFrames * kMaxChannels * sizeof(Float32));
    }
    slot->ioClients++;
    pthread_mutex_unlock(&slot->ioMutex);
    return noErr;
}

static OSStatus StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    UInt32 s, kind;
    if (inDriver != gDriverRef || !DecodeObject(inDeviceObjectID, &s, &kind)) return kAudioHardwareBadObjectError;
    Slot *slot = &gSlots[s];
    pthread_mutex_lock(&slot->ioMutex);
    if (slot->ioClients > 0) slot->ioClients--;
    pthread_mutex_unlock(&slot->ioMutex);
    return noErr;
}

static OSStatus GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)inClientID;
    UInt32 s, kind;
    if (inDriver != gDriverRef || !DecodeObject(inDeviceObjectID, &s, &kind)) return kAudioHardwareBadObjectError;
    Slot *slot = &gSlots[s];
    pthread_mutex_lock(&slot->ioMutex);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = slot->hostTicksPerFrame * (Float64)kZeroTimeStampPeriod;
    UInt64 next = slot->anchorHostTime + (UInt64)((Float64)(slot->numberTimeStamps + 1) * ticksPerPeriod);
    if (next <= now) slot->numberTimeStamps++;
    *outSampleTime = (Float64)(slot->numberTimeStamps * kZeroTimeStampPeriod);
    *outHostTime = slot->anchorHostTime + (UInt64)((Float64)slot->numberTimeStamps * ticksPerPeriod);
    *outSeed = slot->timestampSeed;
    pthread_mutex_unlock(&slot->ioMutex);
    return noErr;
}

static OSStatus WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)inClientID;
    UInt32 s, kind;
    if (inDriver != gDriverRef || !DecodeObject(inDeviceObjectID, &s, &kind)) return kAudioHardwareBadObjectError;
    bool willDo = (kind == kSlotOutDevice && inOperationID == kAudioServerPlugInIOOperationWriteMix)
        || (kind == kSlotCapDevice && inOperationID == kAudioServerPlugInIOOperationReadInput);
    if (outWillDo) *outWillDo = willDo;
    if (outWillDoInPlace) *outWillDoInPlace = true;
    return noErr;
}

static OSStatus BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return noErr;
}

static OSStatus DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer) {
    (void)inClientID; (void)inStreamObjectID; (void)ioSecondaryBuffer;
    UInt32 s, kind;
    if (inDriver != gDriverRef || !DecodeObject(inDeviceObjectID, &s, &kind) || !ioMainBuffer || !inIOCycleInfo) return kAudioHardwareBadObjectError;
    Slot *slot = &gSlots[s];
    Float32 *ring = slot->ring;
    if (!ring) return noErr;
    UInt32 channels = slot->channels;
    Float32 *buffer = ioMainBuffer;

    if (kind == kSlotOutDevice && inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        Float32 gain = SlotGain(slot);
        VespertineSoundWriteRing(ring, kRingFrames, kMaxChannels, buffer, inIOBufferFrameSize, channels,
                                 (UInt64)inIOCycleInfo->mOutputTime.mSampleTime, gain);
    } else if (kind == kSlotCapDevice && inOperationID == kAudioServerPlugInIOOperationReadInput) {
        VespertineSoundReadRing(ring, kRingFrames, kMaxChannels, buffer, inIOBufferFrameSize, channels,
                                (UInt64)inIOCycleInfo->mInputTime.mSampleTime);
    }
    return noErr;
}

static OSStatus EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return noErr;
}
