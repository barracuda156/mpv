/*
 * This file is part of mpv.
 *
 * mpv is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.
 *
 * mpv is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *
 * You should have received a copy of the GNU Lesser General Public
 * License along with mpv.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <CoreAudio/HostTime.h>
#include <libavutil/mathematics.h>

#include "ao.h"
#include "internal.h"
#include "audio/format.h"
#include "osdep/timer.h"
#include "options/m_option.h"
#include "common/msg.h"
#include "ao_coreaudio_chmap.h"
#include "ao_coreaudio_properties.h"
#include "ao_coreaudio_utils.h"
#include "osdep/mac/compat.h"

#if MAC_OS_X_VERSION_MIN_REQUIRED < 1060
typedef Component AudioComponent;
typedef ComponentDescription AudioComponentDescription;
#define AudioComponentFindNext FindNextComponent
#define AudioComponentInstanceNew OpenAComponent
#define AudioComponentInstanceDispose CloseComponent
#endif

#ifndef kAudioObjectPropertyElementMain
#define kAudioObjectPropertyElementMain kAudioObjectPropertyElementMaster
#endif

#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1060
#define USE_DISPATCH 1
#else
#define USE_DISPATCH 0
#endif

#if USE_DISPATCH
// The timeout for stopping the audio unit after being reset. This allows the
// device to sleep after playback paused. The duration is chosen to match the
// behavior of AVFoundation.
#define IDLE_TIME 7 * NSEC_PER_SEC

#if MAC_OS_X_VERSION_MAX_ALLOWED < 1090
#define DISPATCH_QUEUE_SERIAL NULL
#define SOURCE_TIMER_MASK 0
#else
#define SOURCE_TIMER_MASK DISPATCH_TIMER_STRICT
#endif
#endif // USE_DISPATCH

struct priv {
    // This must be put in the front
    struct coreaudio_cb_sem sem;

    AudioDeviceID device;
    AudioUnit audio_unit;

    uint64_t hw_latency_ns;

    AudioStreamBasicDescription original_asbd;
    AudioStreamID original_asbd_stream;

    bool change_physical_format;

    // Optional bit-perfect-ish output without exclusive/hog mode: set the
    // device's nominal sample rate to match the source (snapped to the closest
    // available rate) so CoreAudio does not resample. Restored on uninit.
    bool change_nominal_rate;
    double original_nominal_rate; // 0 == not changed / nothing to restore

#if USE_DISPATCH
    // Timer source that fires after `IDLE_TIME` to stop audio output unit.
    // We use dispatch_source_t instead of dispatch_block_t for better
    // compatibility with GCC (blocks require clang runtime).
    dispatch_source_t idle_timer;
    dispatch_queue_t queue;
#endif

    int hotplug_cb_registration_times;
};

static int64_t ca_get_hardware_latency(struct ao *ao) {
    struct priv *p = ao->priv;

    double audiounit_latency_sec = 0.0;
    uint32_t size = sizeof(audiounit_latency_sec);
    OSStatus err = AudioUnitGetProperty(
            p->audio_unit,
            kAudioUnitProperty_Latency,
            kAudioUnitScope_Global,
            0,
            &audiounit_latency_sec,
            &size);
    CHECK_CA_ERROR("cannot get audio unit latency");

    uint64_t audiounit_latency_ns = MP_TIME_S_TO_NS(audiounit_latency_sec);
    uint64_t device_latency_ns    = ca_get_device_latency_ns(ao, p->device);

    MP_VERBOSE(ao, "audiounit latency [ns]: %lld\n", audiounit_latency_ns);
    MP_VERBOSE(ao, "device latency [ns]: %lld\n", device_latency_ns);

    return audiounit_latency_ns + device_latency_ns;

coreaudio_error:
    return 0;
}

static OSStatus render_cb_lpcm(void *ctx, AudioUnitRenderActionFlags *aflags,
                              const AudioTimeStamp *ts, UInt32 bus,
                              UInt32 frames, AudioBufferList *buffer_list)
{
    struct ao *ao   = ctx;
    struct priv *p  = ao->priv;
    void *planes[MP_NUM_CHANNELS] = {0};

    for (int n = 0; n < ao->num_planes; n++)
        planes[n] = buffer_list->mBuffers[n].mData;

    int64_t end = mp_time_ns();
    end += p->hw_latency_ns + ca_get_latency(ts) + ca_frames_to_ns(ao, frames);
    // don't use the returned sample count since CoreAudio always expects full frames
    ao_read_data(ao, planes, frames, end, NULL, true, true);
    return noErr;
}

static int get_volume(struct ao *ao, float *vol) {
    struct priv *p = ao->priv;
    float auvol;
    OSStatus err =
        AudioUnitGetParameter(p->audio_unit, kHALOutputParam_Volume,
                              kAudioUnitScope_Global, 0, &auvol);

    CHECK_CA_ERROR("could not get HAL output volume");
    *vol = auvol * 100.0;
    return CONTROL_TRUE;
coreaudio_error:
    return CONTROL_ERROR;
}

static int set_volume(struct ao *ao, float *vol) {
    struct priv *p = ao->priv;
    float auvol = *vol / 100.0;
    OSStatus err =
        AudioUnitSetParameter(p->audio_unit, kHALOutputParam_Volume,
                              kAudioUnitScope_Global, 0, auvol, 0);
    CHECK_CA_ERROR("could not set HAL output volume");
    return CONTROL_TRUE;
coreaudio_error:
    return CONTROL_ERROR;
}

static int control(struct ao *ao, enum aocontrol cmd, void *arg)
{
    switch (cmd) {
    case AOCONTROL_GET_VOLUME:
        return get_volume(ao, arg);
    case AOCONTROL_SET_VOLUME:
        return set_volume(ao, arg);
    }
    return CONTROL_UNKNOWN;
}

static bool init_audiounit(struct ao *ao, AudioStreamBasicDescription asbd, AudioChannelLayout *layout, size_t layout_size);
static void init_physical_format(struct ao *ao);
static void reinit_latency(struct ao *ao);
static bool register_hotplug_cb(struct ao *ao);
static void unregister_hotplug_cb(struct ao *ao);
static void uninit(struct ao *ao);

static void stop(struct ao *ao)
{
    struct priv *p = ao->priv;
    OSStatus err = AudioOutputUnitStop(p->audio_unit);
    CHECK_CA_WARN("can't stop audio unit");
}

#if USE_DISPATCH
// Idle timer handler - called when the timer fires
static void idle_timer_handler(void *ctx)
{
    struct ao *ao = ctx;
    MP_VERBOSE(ao, "Stopping audio unit due to idle timeout\n");
    stop(ao);
}

// Initialize the dispatch queue and idle timer
static void init_idle_stop_timer(struct ao *ao)
{
    struct priv *p = ao->priv;

    p->queue = dispatch_queue_create("io.mpv.coreaudio_stop_during_idle",
                                     DISPATCH_QUEUE_SERIAL);

    p->idle_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0,
                                           SOURCE_TIMER_MASK, p->queue);

    dispatch_source_set_event_handler_f(p->idle_timer, idle_timer_handler);
    dispatch_set_context(p->idle_timer, ao);

    // macOS 10.9+ requires dispatch_activate, earlier versions use dispatch_resume
#if MAC_OS_X_VERSION_MIN_REQUIRED >= 1090
    dispatch_activate(p->idle_timer);
#else
    dispatch_resume(p->idle_timer);
#endif
}

// Cancel the idle timer (set it to never fire)
static void cancel_idle_timer(dispatch_source_t timer)
{
    dispatch_source_set_timer(timer, DISPATCH_TIME_FOREVER,
                              DISPATCH_TIME_FOREVER, 0);
}

// Schedule the idle timer to fire after IDLE_TIME
static void schedule_idle_timer(dispatch_source_t timer)
{
    dispatch_source_set_timer(timer,
                              dispatch_time(DISPATCH_TIME_NOW, IDLE_TIME),
                              DISPATCH_TIME_FOREVER, 0);
}

// Clean up the idle timer
static void cleanup_idle_timer(struct priv *p)
{
    if (p->idle_timer) {
        dispatch_source_cancel(p->idle_timer);
        dispatch_release(p->idle_timer);
        p->idle_timer = NULL;
    }
    if (p->queue) {
        dispatch_release(p->queue);
        p->queue = NULL;
    }
}
#endif // USE_DISPATCH

static bool reinit_device(struct ao *ao) {
    struct priv *p = ao->priv;

    OSStatus err = ca_select_device(ao, ao->device, &p->device);
    CHECK_CA_ERROR("failed to select device");

    return true;

coreaudio_error:
    return false;
}

// Pick the device nominal sample rate closest to the source rate, out of the
// device's advertised AvailableNominalSampleRates. Each entry is a range
// (continuous-rate devices report min != max); snap to the nearest bound.
static double ca_closest_nominal_rate(struct ao *ao, double want)
{
    struct priv *p = ao->priv;
    AudioValueRange *ranges = NULL;
    size_t n = 0;
    double best = 0;
    double best_dist = 0;

    OSStatus err = CA_GET_ARY(p->device,
                              kAudioDevicePropertyAvailableNominalSampleRates,
                              &ranges, &n);
    if (err != noErr || !n) {
        talloc_free(ranges);
        return 0;
    }

    for (size_t i = 0; i < n; i++) {
        // Clamp the wanted rate into this range, then take that as a candidate.
        double cand = want;
        if (cand < ranges[i].mMinimum)
            cand = ranges[i].mMinimum;
        if (cand > ranges[i].mMaximum)
            cand = ranges[i].mMaximum;
        double dist = cand - want;
        if (dist < 0)
            dist = -dist;
        if (!best || dist < best_dist) {
            best = cand;
            best_dist = dist;
        }
    }

    talloc_free(ranges);
    return best;
}

// Set the device nominal sample rate to match the source (no hog mode, no
// mixing changes) so CoreAudio performs no sample-rate conversion. Caches the
// previous rate in p->original_nominal_rate for restoration in uninit().
static void ca_set_nominal_rate(struct ao *ao)
{
    struct priv *p = ao->priv;

    double cur = 0;
    OSStatus err = CA_GET(p->device, kAudioDevicePropertyNominalSampleRate, &cur);
    if (err != noErr) {
        MP_WARN(ao, "could not get device nominal sample rate\n");
        return;
    }

    double want = ca_closest_nominal_rate(ao, ao->samplerate);
    if (!want) {
        MP_WARN(ao, "could not query available device sample rates\n");
        return;
    }

    if (want != ao->samplerate) {
        MP_VERBOSE(ao, "no exact device rate for %d Hz; using closest %.0f Hz\n",
                   ao->samplerate, want);
    }

    if (want == cur) {
        MP_VERBOSE(ao, "device already at %.0f Hz, not changing\n", cur);
        return;
    }

    err = CA_SET(p->device, kAudioDevicePropertyNominalSampleRate, &want);
    if (err != noErr) {
        MP_WARN(ao, "could not set device nominal sample rate to %.0f Hz\n", want);
        return;
    }

    p->original_nominal_rate = cur;
    MP_VERBOSE(ao, "set device nominal sample rate %.0f -> %.0f Hz\n", cur, want);
}

static int init(struct ao *ao)
{
    struct priv *p = ao->priv;

    if (!af_fmt_is_pcm(ao->format) || (ao->init_flags & AO_INIT_EXCLUSIVE)) {
        MP_VERBOSE(ao, "redirecting to coreaudio_exclusive\n");
        ao->redirect = "coreaudio_exclusive";
        return CONTROL_ERROR;
    }

    if (!reinit_device(ao))
        goto coreaudio_error;

    if (p->change_physical_format)
        init_physical_format(ao);

    // Match the device nominal rate to the source before configuring the audio
    // unit, so CoreAudio does no resampling. Best-effort: on failure we simply
    // fall through to the normal (resampled) path. No hog mode is taken, so
    // this cannot wedge the device the way the exclusive backend can.
    if (p->change_nominal_rate)
        ca_set_nominal_rate(ao);

    if (!ca_init_chmap(ao, p->device))
        goto coreaudio_error;

    AudioStreamBasicDescription asbd;
    ca_fill_asbd(ao, &asbd);
    size_t layout_size;
    AudioChannelLayout *layout = ca_get_acl(ao, &layout_size);

    bool r = init_audiounit(ao, asbd, layout, layout_size);
    talloc_free(layout);

    if (!r)
        goto coreaudio_error;

    if (!register_hotplug_cb(ao))
        goto coreaudio_error;

    reinit_latency(ao);
    ao->device_buffer = av_rescale(p->hw_latency_ns, ao->samplerate, 1000000000) * 2;

#if USE_DISPATCH
    init_idle_stop_timer(ao);
#endif

    return CONTROL_OK;

coreaudio_error:
    uninit(ao);
    return CONTROL_ERROR;
}

static void init_physical_format(struct ao *ao)
{
    struct priv *p = ao->priv;
    OSErr err;

    void *tmp = talloc_new(NULL);

    AudioStreamBasicDescription asbd;
    ca_fill_asbd(ao, &asbd);

    AudioStreamID *streams;
    size_t n_streams;

    err = CA_GET_ARY_O(p->device, kAudioDevicePropertyStreams,
                       &streams, &n_streams);
    CHECK_CA_ERROR("could not get number of streams");

    talloc_steal(tmp, streams);

    MP_VERBOSE(ao, "Found %zd substream(s).\n", n_streams);

    for (int i = 0; i < n_streams; i++) {
        AudioStreamRangedDescription *formats;
        size_t n_formats;

        MP_VERBOSE(ao, "Looking at formats in substream %d...\n", i);

        err = CA_GET_ARY(streams[i], kAudioStreamPropertyAvailablePhysicalFormats,
                         &formats, &n_formats);

        if (!CHECK_CA_WARN("could not get number of stream formats"))
            continue; // try next one

        talloc_steal(tmp, formats);

        uint32_t direction;
        err = CA_GET(streams[i], kAudioStreamPropertyDirection, &direction);
        CHECK_CA_ERROR("could not get stream direction");
        if (direction != 0) {
            MP_VERBOSE(ao, "Not an output stream.\n");
            continue;
        }

        AudioStreamBasicDescription best_asbd = {0};

        for (int j = 0; j < n_formats; j++) {
            AudioStreamBasicDescription *stream_asbd = &formats[j].mFormat;

            ca_print_asbd(ao, "- ", stream_asbd);

            if (!best_asbd.mFormatID || ca_asbd_is_better(&asbd, &best_asbd,
                                                          stream_asbd))
                best_asbd = *stream_asbd;
        }

        if (best_asbd.mFormatID) {
            p->original_asbd_stream = streams[i];
            err = CA_GET(p->original_asbd_stream,
                         kAudioStreamPropertyPhysicalFormat,
                         &p->original_asbd);
            CHECK_CA_WARN("could not get current physical stream format");

            if (ca_asbd_equals(&p->original_asbd, &best_asbd)) {
                MP_VERBOSE(ao, "Requested format already set, not changing.\n");
                p->original_asbd.mFormatID = 0;
                break;
            }

            if (!ca_change_physical_format_sync(ao, streams[i], best_asbd))
                p->original_asbd = (AudioStreamBasicDescription){0};
            break;
        }
    }

coreaudio_error:
    talloc_free(tmp);
}

static bool init_audiounit(struct ao *ao, AudioStreamBasicDescription asbd, AudioChannelLayout *layout, size_t layout_size)
{
    OSStatus err;
    uint32_t size;
    struct priv *p = ao->priv;

    AudioComponentDescription desc = (AudioComponentDescription) {
        .componentType         = kAudioUnitType_Output,
        .componentSubType      = (ao->device) ?
                                    kAudioUnitSubType_HALOutput :
                                    kAudioUnitSubType_DefaultOutput,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
        .componentFlags        = 0,
        .componentFlagsMask    = 0,
    };

    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    if (comp == NULL) {
        MP_ERR(ao, "unable to find audio component\n");
        goto coreaudio_error;
    }

    err = AudioComponentInstanceNew(comp, &(p->audio_unit));
    CHECK_CA_ERROR("unable to open audio component");

    err = AudioUnitInitialize(p->audio_unit);
    CHECK_CA_ERROR_L(coreaudio_error_component,
                     "unable to initialize audio unit");

    size = sizeof(AudioStreamBasicDescription);
    err = AudioUnitSetProperty(p->audio_unit,
                               kAudioUnitProperty_StreamFormat,
                               kAudioUnitScope_Input, 0, &asbd, size);

    CHECK_CA_ERROR_L(coreaudio_error_audiounit,
                     "unable to set the input format on the audio unit");

    err = AudioUnitSetProperty(p->audio_unit,
                               kAudioOutputUnitProperty_CurrentDevice,
                               kAudioUnitScope_Global, 0, &p->device,
                               sizeof(p->device));
    CHECK_CA_ERROR_L(coreaudio_error_audiounit,
                     "can't link audio unit to selected device");

    err = AudioUnitSetProperty(p->audio_unit,
                               kAudioOutputUnitProperty_ChannelMap,
                               kAudioUnitScope_Global, 0, layout, layout_size);

    CHECK_CA_ERROR_L(coreaudio_error_audiounit,
                     "unable to set the input channel layout on the audio unit");

    AURenderCallbackStruct render_cb = (AURenderCallbackStruct) {
        .inputProc       = render_cb_lpcm,
        .inputProcRefCon = ao,
    };

    err = AudioUnitSetProperty(p->audio_unit,
                               kAudioUnitProperty_SetRenderCallback,
                               kAudioUnitScope_Input, 0, &render_cb,
                               sizeof(AURenderCallbackStruct));

    CHECK_CA_ERROR_L(coreaudio_error_audiounit,
                     "unable to set render callback on audio unit");

    return true;

coreaudio_error_audiounit:
    AudioUnitUninitialize(p->audio_unit);
coreaudio_error_component:
    AudioComponentInstanceDispose(p->audio_unit);
coreaudio_error:
    return false;
}

static void reinit_latency(struct ao *ao)
{
    struct priv *p = ao->priv;

    p->hw_latency_ns = ca_get_hardware_latency(ao);
}

#if USE_DISPATCH
static void _reset(void *_ao)
{
    struct ao *ao = (struct ao *)_ao;
    struct priv *p = ao->priv;
    OSStatus err = AudioUnitReset(p->audio_unit, kAudioUnitScope_Global, 0);
    CHECK_CA_WARN("can't reset audio unit");

    // Until the audio unit is stopped the macOS daemon coreaudiod continues to
    // consume CPU and prevent macOS from sleeping. Immediately stopping the
    // audio unit would be disruptive for short pause/resume cycles as
    // restarting the audio unit takes a noticeable amount of time when a
    // wireless audio device is being used. Instead the audio unit is stopped
    // after a delay if it remains idle.
    schedule_idle_timer(p->idle_timer);
}

static void _start(void *_ao)
{
    struct ao *ao = (struct ao *)_ao;
    struct priv *p = ao->priv;

    cancel_idle_timer(p->idle_timer);

    OSStatus err = AudioOutputUnitStart(p->audio_unit);
    CHECK_CA_WARN("can't start audio unit");
}
#endif // USE_DISPATCH

static void reset(struct ao *ao)
{
#if USE_DISPATCH
    struct priv *p = ao->priv;
    // Must dispatch to serialize reset, start and stop operations.
    dispatch_sync_f(p->queue, ao, &_reset);
#else
    // Without dispatch, just reset and stop immediately
    struct priv *p = ao->priv;
    OSStatus err = AudioUnitReset(p->audio_unit, kAudioUnitScope_Global, 0);
    CHECK_CA_WARN("can't reset audio unit");
    stop(ao);
#endif
}

static void start(struct ao *ao)
{
#if USE_DISPATCH
    struct priv *p = ao->priv;
    // Must dispatch to serialize reset, start and stop operations.
    dispatch_sync_f(p->queue, ao, &_start);
#else
    // Without dispatch, just start immediately
    struct priv *p = ao->priv;
    OSStatus err = AudioOutputUnitStart(p->audio_unit);
    CHECK_CA_WARN("can't start audio unit");
#endif
}

static void uninit(struct ao *ao)
{
    struct priv *p = ao->priv;

#if USE_DISPATCH
    cleanup_idle_timer(p);
#endif

    if (p->audio_unit) {
        AudioOutputUnitStop(p->audio_unit);
        AudioUnitUninitialize(p->audio_unit);
        AudioComponentInstanceDispose(p->audio_unit);
    }

    if (p->original_asbd.mFormatID) {
        OSStatus err = CA_SET(p->original_asbd_stream,
                              kAudioStreamPropertyPhysicalFormat,
                              &p->original_asbd);
        CHECK_CA_WARN("could not restore physical stream format");
    }

    if (p->original_nominal_rate) {
        OSStatus err = CA_SET(p->device, kAudioDevicePropertyNominalSampleRate,
                              &p->original_nominal_rate);
        CHECK_CA_WARN("could not restore device nominal sample rate");
        p->original_nominal_rate = 0;
    }

    unregister_hotplug_cb(ao);
}

static OSStatus hotplug_cb(AudioObjectID id, UInt32 naddr,
                           const AudioObjectPropertyAddress addr[],
                           void *ctx)
{
    struct ao *ao = ctx;
    struct priv *p = ao->priv;
    MP_VERBOSE(ao, "Handling potential hotplug event...\n");
    reinit_device(ao);
    if (p->audio_unit)
        reinit_latency(ao);
    ao_hotplug_event(ao);
    return noErr;
}

static uint32_t hotplug_properties[] = {
    kAudioHardwarePropertyDevices,
    kAudioHardwarePropertyDefaultOutputDevice
};

static int hotplug_init(struct ao *ao)
{
    if (!reinit_device(ao))
        return -1;

    if (!register_hotplug_cb(ao))
        return -1;

    return 0;
}

static void hotplug_uninit(struct ao *ao)
{
    unregister_hotplug_cb(ao);
}

static bool register_hotplug_cb(struct ao *ao)
{
    struct priv *p = ao->priv;

    if (p->hotplug_cb_registration_times++)
        return true;

    OSStatus err = noErr;
    for (int i = 0; i < MP_ARRAY_SIZE(hotplug_properties); i++) {
        AudioObjectPropertyAddress addr = {
            hotplug_properties[i],
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        err = AudioObjectAddPropertyListener(
            kAudioObjectSystemObject, &addr, hotplug_cb, (void *)ao);
        if (err != noErr) {
            char *c1 = mp_tag_str(hotplug_properties[i]);
            char *c2 = mp_tag_str(err);
            MP_ERR(ao, "failed to set device listener %s (%s)", c1, c2);
            goto coreaudio_error;
        }
    }

    return true;

coreaudio_error:
    return false;
}

static void unregister_hotplug_cb(struct ao *ao)
{
    struct priv *p = ao->priv;

    if (--p->hotplug_cb_registration_times)
        return;

    OSStatus err = noErr;
    for (int i = 0; i < MP_ARRAY_SIZE(hotplug_properties); i++) {
        AudioObjectPropertyAddress addr = {
            hotplug_properties[i],
            kAudioObjectPropertyScopeGlobal,
            kAudioObjectPropertyElementMain
        };
        err = AudioObjectRemovePropertyListener(
            kAudioObjectSystemObject, &addr, hotplug_cb, (void *)ao);
        if (err != noErr) {
            char *c1 = mp_tag_str(hotplug_properties[i]);
            char *c2 = mp_tag_str(err);
            MP_ERR(ao, "failed to set device listener %s (%s)", c1, c2);
        }
    }
}

#define OPT_BASE_STRUCT struct priv

const struct ao_driver audio_out_coreaudio = {
    .description    = "CoreAudio AudioUnit",
    .name           = "coreaudio",
    .uninit         = uninit,
    .init           = init,
    .control        = control,
    .reset          = reset,
    .start          = start,
    .hotplug_init   = hotplug_init,
    .hotplug_uninit = hotplug_uninit,
    .list_devs      = ca_get_device_list,
    .priv_size      = sizeof(struct priv),
    .priv_defaults  = &(const struct priv){
        .sem = (struct coreaudio_cb_sem){
            .mutex = MP_STATIC_MUTEX_INITIALIZER,
            .cond = MP_STATIC_COND_INITIALIZER,
        }
    },
    .options = (const struct m_option[]){
        {"change-physical-format", OPT_BOOL(change_physical_format)},
        {"change-nominal-rate", OPT_BOOL(change_nominal_rate)},
        {0}
    },
    .options_prefix = "coreaudio",
};
