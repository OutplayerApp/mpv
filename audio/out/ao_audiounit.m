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

#include "ao.h"
#include "internal.h"
#include "audio/format.h"
#include "osdep/timer.h"
#include "options/m_option.h"
#include "common/msg.h"
#include "ao_coreaudio_utils.h"
#include "ao_coreaudio_chmap.h"
#include "options/m_config_core.h"

#import <AudioUnit/AudioUnit.h>
#import <CoreAudio/CoreAudioTypes.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <mach/mach_time.h>

struct audiounit_opts {
    int spatial_audio;  // 0=no, 1=yes, 2=head-tracking
};

static const struct m_sub_options ao_audiounit_conf;

#define SPATIAL_MAX_CH 16

struct priv {
    AudioUnit audio_unit;
    AudioUnit spatial_mixer;
    bool spatial_enabled;
    double device_latency;
    // Pre-allocated buffers for spatial mixer render output (non-interleaved)
    float *mixer_buf[SPATIAL_MAX_CH];
    int spatial_out_ch;
    UInt32 mixer_buf_frames;
    // Pre-allocated AudioBufferList for the spatial mixer render callback.
    // AudioBufferList has a variable-length mBuffers[1], so this is heap-allocated
    // at init time with room for spatial_out_ch entries.
    AudioBufferList *spatial_abl;
    id route_change_observer;
};

static OSStatus au_get_ary(AudioUnit unit, AudioUnitPropertyID inID,
                           AudioUnitScope inScope, AudioUnitElement inElement,
                           void **data, UInt32 *outDataSize)
{
    OSStatus err;

    err = AudioUnitGetPropertyInfo(unit, inID, inScope, inElement, outDataSize, NULL);
    CHECK_CA_ERROR_SILENT_L(coreaudio_error);

    *data = talloc_zero_size(NULL, *outDataSize);

    err = AudioUnitGetProperty(unit, inID, inScope, inElement, *data, outDataSize);
    CHECK_CA_ERROR_SILENT_L(coreaudio_error_free);

    return err;
coreaudio_error_free:
    talloc_free(*data);
coreaudio_error:
    return err;
}

static AudioChannelLayout *convert_layout(AudioChannelLayout *layout, UInt32 *size)
{
    AudioChannelLayoutTag tag = layout->mChannelLayoutTag;
    AudioChannelLayout *new_layout;
    if (tag == kAudioChannelLayoutTag_UseChannelDescriptions)
        return layout;
    else if (tag == kAudioChannelLayoutTag_UseChannelBitmap)
        AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForBitmap,
                                   sizeof(UInt32), &layout->mChannelBitmap, size);
    else
        AudioFormatGetPropertyInfo(kAudioFormatProperty_ChannelLayoutForTag,
                                   sizeof(AudioChannelLayoutTag), &tag, size);
    new_layout = talloc_zero_size(NULL, *size);
    if (!new_layout) {
        talloc_free(layout);
        return NULL;
    }
    if (tag == kAudioChannelLayoutTag_UseChannelBitmap)
        AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForBitmap,
                               sizeof(UInt32), &layout->mChannelBitmap, size, new_layout);
    else
        AudioFormatGetProperty(kAudioFormatProperty_ChannelLayoutForTag,
                               sizeof(AudioChannelLayoutTag), &tag, size, new_layout);
    new_layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
    talloc_free(layout);
    return new_layout;
}

// Detect the spatial mixer output type based on the current audio route
static AUSpatialMixerOutputType get_spatial_output_type(void)
{
    AVAudioSession *session = [AVAudioSession sharedInstance];
    NSArray<AVAudioSessionPortDescription *> *outputs = session.currentRoute.outputs;

    if ([outputs count] != 1)
        return kSpatialMixerOutputType_ExternalSpeakers;

    NSString *portType = outputs.firstObject.portType;
    if ([portType isEqualToString:AVAudioSessionPortHeadphones] ||
        [portType isEqualToString:AVAudioSessionPortBluetoothA2DP] ||
        [portType isEqualToString:AVAudioSessionPortBluetoothLE] ||
        [portType isEqualToString:AVAudioSessionPortBluetoothHFP])
        return kSpatialMixerOutputType_Headphones;
    else if ([portType isEqualToString:AVAudioSessionPortBuiltInSpeaker])
        return kSpatialMixerOutputType_BuiltInSpeakers;
    else
        return kSpatialMixerOutputType_ExternalSpeakers;
}

// Render callback for the spatial mixer's input: pulls multichannel audio from mpv
static OSStatus spatial_input_cb(void *ctx, AudioUnitRenderActionFlags *aflags,
                                 const AudioTimeStamp *ts, UInt32 bus,
                                 UInt32 frames, AudioBufferList *buffer_list)
{
    struct ao *ao = ctx;
    struct priv *p = ao->priv;
    void *planes[MP_NUM_CHANNELS] = {0};

    for (int n = 0; n < ao->num_planes; n++)
        planes[n] = buffer_list->mBuffers[n].mData;

    int64_t end = mp_time_ns();
    end += MP_TIME_S_TO_NS(p->device_latency);
    end += ca_get_latency(ts) + ca_frames_to_ns(ao, frames);
    ao_read_data(ao, planes, frames, end, NULL, true, true);
    return noErr;
}

// Render callback for RemoteIO output: renders through the spatial mixer
static OSStatus spatial_output_cb(void *ctx, AudioUnitRenderActionFlags *aflags,
                                  const AudioTimeStamp *ts, UInt32 bus,
                                  UInt32 frames, AudioBufferList *buffer_list)
{
    struct ao *ao = ctx;
    struct priv *p = ao->priv;

    // Safety: if the requested frame count exceeds our pre-allocated buffer,
    // output silence rather than overflowing. This should not happen if
    // kAudioUnitProperty_MaximumFramesPerSlice is set correctly.
    if (frames > p->mixer_buf_frames) {
        for (UInt32 i = 0; i < buffer_list->mNumberBuffers; i++)
            memset(buffer_list->mBuffers[i].mData, 0, buffer_list->mBuffers[i].mDataByteSize);
        return noErr;
    }

    // Update pre-allocated AudioBufferList with current frame size.
    // The mData pointers and mNumberChannels are stable from init time;
    // only mDataByteSize changes per callback (just integer writes, no allocation).
    for (int i = 0; i < p->spatial_out_ch; i++)
        p->spatial_abl->mBuffers[i].mDataByteSize = frames * sizeof(float);

    // Pull processed audio from the spatial mixer
    AudioUnitRenderActionFlags actionFlags = 0;
    OSStatus err = AudioUnitRender(p->spatial_mixer, &actionFlags, ts, 0,
                                   frames, p->spatial_abl);
    if (err != noErr) {
        for (UInt32 i = 0; i < buffer_list->mNumberBuffers; i++)
            memset(buffer_list->mBuffers[i].mData, 0, buffer_list->mBuffers[i].mDataByteSize);
        return noErr;
    }

    // Copy spatial mixer output (non-interleaved) to RemoteIO output buffer.
    // RemoteIO is configured as non-interleaved to match, so this is a direct copy.
    for (UInt32 i = 0; i < buffer_list->mNumberBuffers && i < (UInt32)p->spatial_out_ch; i++)
        memcpy(buffer_list->mBuffers[i].mData, p->mixer_buf[i], frames * sizeof(float));

    return noErr;
}

// Render callback for direct output (no spatial mixer)
static OSStatus render_cb_lpcm(void *ctx, AudioUnitRenderActionFlags *aflags,
                               const AudioTimeStamp *ts, UInt32 bus,
                               UInt32 frames, AudioBufferList *buffer_list)
{
    struct ao *ao = ctx;
    struct priv *p = ao->priv;
    void *planes[MP_NUM_CHANNELS] = {0};

    for (int n = 0; n < ao->num_planes; n++)
        planes[n] = buffer_list->mBuffers[n].mData;

    int64_t end = mp_time_ns();
    end += MP_TIME_S_TO_NS(p->device_latency);
    end += ca_get_latency(ts) + ca_frames_to_ns(ao, frames);
    ao_read_data(ao, planes, frames, end, NULL, true, true);
    return noErr;
}

static bool init_spatial_mixer(struct ao *ao, bool head_tracking,
                               AUSpatialMixerOutputType output_type,
                               int out_channels,
                               AudioChannelLayout *out_acl, UInt32 out_acl_size)
{
    struct priv *p = ao->priv;
    OSStatus err;

    if (out_channels > SPATIAL_MAX_CH) {
        MP_WARN(ao, "spatial mixer: output channels %d exceeds max %d\n",
                out_channels, SPATIAL_MAX_CH);
        return false;
    }

    // Create the spatial mixer audio unit
    AudioComponentDescription mixer_desc = {
        .componentType         = kAudioUnitType_Mixer,
        .componentSubType      = kAudioUnitSubType_SpatialMixer,
        .componentManufacturer = kAudioUnitManufacturer_Apple,
    };

    AudioComponent mixer_comp = AudioComponentFindNext(NULL, &mixer_desc);
    if (!mixer_comp) {
        MP_WARN(ao, "spatial mixer audio unit not available\n");
        return false;
    }

    err = AudioComponentInstanceNew(mixer_comp, &p->spatial_mixer);
    CHECK_CA_ERROR_L(coreaudio_error, "unable to create spatial mixer instance");

    // Set number of input buses to 1
    UInt32 numInputs = 1;
    err = AudioUnitSetProperty(p->spatial_mixer, kAudioUnitProperty_ElementCount,
                               kAudioUnitScope_Input, 0, &numInputs, sizeof(numInputs));
    CHECK_CA_ERROR_L(coreaudio_error_mixer, "unable to set spatial mixer input count");

    // Configure output: non-interleaved float with the caller-specified channel layout.
    // For headphones/built-in speakers this is stereo; for external speakers with
    // multichannel hardware this matches the hardware layout (e.g. 5.1 over HDMI).
    {
        AudioStreamBasicDescription out_asbd = {
            .mSampleRate       = ao->samplerate,
            .mFormatID         = kAudioFormatLinearPCM,
            .mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                                 | kAudioFormatFlagIsNonInterleaved,
            .mBytesPerPacket   = 4,
            .mFramesPerPacket  = 1,
            .mBytesPerFrame    = 4,
            .mChannelsPerFrame = out_channels,
            .mBitsPerChannel   = 32,
        };
        err = AudioUnitSetProperty(p->spatial_mixer, kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Output, 0, &out_asbd,
                                   sizeof(AudioStreamBasicDescription));
        CHECK_CA_ERROR_L(coreaudio_error_mixer, "unable to set spatial mixer output format");

        err = AudioUnitSetProperty(p->spatial_mixer, kAudioUnitProperty_AudioChannelLayout,
                                   kAudioUnitScope_Output, 0, out_acl, out_acl_size);
        CHECK_CA_ERROR_L(coreaudio_error_mixer, "unable to set spatial mixer output layout");
    }

    // Configure input: multichannel non-interleaved float matching mpv's channel layout.
    // Use ca_get_acl to build the channel layout from ao->channels, which automatically
    // finds a matching standard layout tag (e.g. MPEG_5_1_A for 5.1).
    {
        AudioStreamBasicDescription in_asbd = {
            .mSampleRate       = ao->samplerate,
            .mFormatID         = kAudioFormatLinearPCM,
            .mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                                 | kAudioFormatFlagIsNonInterleaved,
            .mBytesPerPacket   = 4,
            .mFramesPerPacket  = 1,
            .mBytesPerFrame    = 4,
            .mChannelsPerFrame = ao->channels.num,
            .mBitsPerChannel   = 32,
        };
        err = AudioUnitSetProperty(p->spatial_mixer, kAudioUnitProperty_StreamFormat,
                                   kAudioUnitScope_Input, 0, &in_asbd,
                                   sizeof(AudioStreamBasicDescription));
        CHECK_CA_ERROR_L(coreaudio_error_mixer, "unable to set spatial mixer input format");

        size_t acl_size;
        AudioChannelLayout *input_acl = ca_get_acl(ao, &acl_size);
        MP_VERBOSE(ao, "spatial mixer input layout tag: %u, channels: %d\n",
                   input_acl->mChannelLayoutTag, ao->channels.num);
        err = AudioUnitSetProperty(p->spatial_mixer, kAudioUnitProperty_AudioChannelLayout,
                                   kAudioUnitScope_Input, 0, input_acl, (UInt32)acl_size);
        CHECK_CA_ERROR_L(coreaudio_error_mixer, "unable to set spatial mixer input layout");
    }

    // Set spatialization algorithm
    UInt32 algorithm = kSpatializationAlgorithm_UseOutputType;
    err = AudioUnitSetProperty(p->spatial_mixer, kAudioUnitProperty_SpatializationAlgorithm,
                               kAudioUnitScope_Input, 0, &algorithm, sizeof(algorithm));
    CHECK_CA_ERROR_L(coreaudio_error_mixer, "unable to set spatialization algorithm");

    // Set source mode to ambience bed (appropriate for channel-bed movie audio)
    UInt32 sourceMode = kSpatialMixerSourceMode_AmbienceBed;
    err = AudioUnitSetProperty(p->spatial_mixer, kAudioUnitProperty_SpatialMixerSourceMode,
                               kAudioUnitScope_Input, 0, &sourceMode, sizeof(sourceMode));
    CHECK_CA_ERROR_L(coreaudio_error_mixer, "unable to set spatial mixer source mode");

    // Set output type (determined by caller based on current audio route)
    err = AudioUnitSetProperty(p->spatial_mixer, kAudioUnitProperty_SpatialMixerOutputType,
                               kAudioUnitScope_Global, 0, &output_type, sizeof(output_type));
    CHECK_CA_ERROR_L(coreaudio_error_mixer, "unable to set spatial mixer output type");

    MP_VERBOSE(ao, "spatial mixer output type: %u (%s), output channels: %d\n", output_type,
               output_type == kSpatialMixerOutputType_Headphones ? "headphones" :
               output_type == kSpatialMixerOutputType_BuiltInSpeakers ? "built-in speakers" :
               "external speakers", out_channels);

    // Enable head-tracking and personalized HRTF for headphones on iOS 18+
    if (head_tracking && output_type == kSpatialMixerOutputType_Headphones) {
        if (@available(iOS 18.0, *)) {
            UInt32 ht = 1;
            err = AudioUnitSetProperty(p->spatial_mixer,
                                       kAudioUnitProperty_SpatialMixerEnableHeadTracking,
                                       kAudioUnitScope_Global, 0, &ht, sizeof(UInt32));
            if (err == noErr) {
                MP_VERBOSE(ao, "head-tracking enabled\n");
            } else {
                MP_VERBOSE(ao, "head-tracking not available (err=%d)\n", (int)err);
            }

            UInt32 hrtf = kSpatialMixerPersonalizedHRTFMode_Auto;
            err = AudioUnitSetProperty(p->spatial_mixer,
                                       kAudioUnitProperty_SpatialMixerPersonalizedHRTFMode,
                                       kAudioUnitScope_Global, 0, &hrtf, sizeof(UInt32));
            if (err == noErr) {
                MP_VERBOSE(ao, "personalized HRTF enabled\n");
            } else {
                MP_VERBOSE(ao, "personalized HRTF not available (err=%d)\n", (int)err);
            }
        }
    }

    // Apply a factory preset tuned for media playback. The preset is chosen
    // based on the output type. Note: presets can override previously set
    // properties, so this must come after algorithm/source mode configuration.
    //   ID 0: Built-In Speaker Media Playback
    //   ID 1: Headphone Media Playback Default
    //   ID 2: Headphone Media Playback Movie
    if (@available(iOS 18.0, *)) {
        SInt32 presetID;
        const char *presetName;
        if (output_type == kSpatialMixerOutputType_BuiltInSpeakers) {
            presetID = 0;
            presetName = "Built-In Speaker Media Playback";
        } else if (output_type == kSpatialMixerOutputType_Headphones) {
            presetID = 2;
            presetName = "Headphone Media Playback Movie";
        } else {
            presetID = -1;
        }
        if (presetID >= 0) {
            AUPreset preset = { .presetNumber = presetID, .presetName = NULL };
            err = AudioUnitSetProperty(p->spatial_mixer, kAudioUnitProperty_PresentPreset,
                                       kAudioUnitScope_Global, 0, &preset, sizeof(AUPreset));
            if (err == noErr) {
                MP_VERBOSE(ao, "applied factory preset %d (%s)\n", presetID, presetName);
            }
        }
    }

    // Set max frames per slice and pre-allocate the intermediate render buffers.
    // These must be allocated here (not in the real-time callback) because
    // memory allocation can take locks and cause priority inversion on the audio thread.
    UInt32 maxFrames = 4096;
    err = AudioUnitSetProperty(p->spatial_mixer, kAudioUnitProperty_MaximumFramesPerSlice,
                               kAudioUnitScope_Global, 0, &maxFrames, sizeof(maxFrames));
    CHECK_CA_ERROR_L(coreaudio_error_mixer, "unable to set max frames per slice");

    p->spatial_out_ch = out_channels;
    p->mixer_buf_frames = maxFrames;
    for (int i = 0; i < out_channels; i++)
        p->mixer_buf[i] = talloc_array(NULL, float, maxFrames);

    // Pre-allocate AudioBufferList with room for out_channels entries.
    // AudioBufferList has a variable-length mBuffers[1], so we compute the
    // actual size needed and heap-allocate to avoid stack corruption.
    size_t abl_size = offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * out_channels;
    p->spatial_abl = talloc_zero_size(NULL, abl_size);
    p->spatial_abl->mNumberBuffers = out_channels;
    for (int i = 0; i < out_channels; i++) {
        p->spatial_abl->mBuffers[i].mNumberChannels = 1;
        p->spatial_abl->mBuffers[i].mData = p->mixer_buf[i];
    }

    // Set up the render callback on the spatial mixer input
    AURenderCallbackStruct render_cb = {
        .inputProc       = spatial_input_cb,
        .inputProcRefCon = ao,
    };
    err = AudioUnitSetProperty(p->spatial_mixer, kAudioUnitProperty_SetRenderCallback,
                               kAudioUnitScope_Input, 0, &render_cb,
                               sizeof(AURenderCallbackStruct));
    CHECK_CA_ERROR_L(coreaudio_error_mixer, "unable to set spatial mixer render callback");

    // Initialize the spatial mixer
    err = AudioUnitInitialize(p->spatial_mixer);
    CHECK_CA_ERROR_L(coreaudio_error_mixer, "unable to initialize spatial mixer");

    MP_INFO(ao, "spatial audio enabled (%d ch in, %d ch out, head-tracking: %s)\n",
            ao->channels.num, out_channels, head_tracking ? "yes" : "no");
    return true;

coreaudio_error_mixer:
    AudioComponentInstanceDispose(p->spatial_mixer);
    p->spatial_mixer = NULL;
    for (int i = 0; i < SPATIAL_MAX_CH; i++) {
        talloc_free(p->mixer_buf[i]);
        p->mixer_buf[i] = NULL;
    }
    talloc_free(p->spatial_abl);
    p->spatial_abl = NULL;
    p->mixer_buf_frames = 0;
    p->spatial_out_ch = 0;
coreaudio_error:
    return false;
}

static bool init_audiounit(struct ao *ao)
{
    AudioStreamBasicDescription asbd;
    OSStatus err;
    uint32_t size;
    AudioChannelLayout *layout = NULL;
    AudioChannelLayout *hw_layout = NULL;
    struct priv *p = ao->priv;
    AVAudioSession *instance = AVAudioSession.sharedInstance;
    NSInteger maxChannels = instance.maximumOutputNumberOfChannels;
    NSInteger prefChannels = MIN(maxChannels, ao->channels.num);

    MP_VERBOSE(ao, "max channels: %ld, requested: %d\n", maxChannels, (int)ao->channels.num);

    AVAudioSessionCategoryOptions options = 0;
    if (!(ao->init_flags & AO_INIT_EXCLUSIVE)) {
        options |= AVAudioSessionCategoryOptionMixWithOthers;
    }

    [instance setCategory:AVAudioSessionCategoryPlayback withOptions:options error:nil];
    [instance setMode:AVAudioSessionModeMoviePlayback error:nil];
    [instance setActive:YES error:nil];
    [instance setPreferredOutputNumberOfChannels:prefChannels error:nil];

    // Create RemoteIO output unit
    AudioComponentDescription desc = (AudioComponentDescription) {
        .componentType         = kAudioUnitType_Output,
        .componentSubType      = kAudioUnitSubType_RemoteIO,
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
    CHECK_CA_ERROR_L(coreaudio_error_component, "unable to initialize audio unit");

    err = au_get_ary(p->audio_unit, kAudioUnitProperty_AudioChannelLayout,
                     kAudioUnitScope_Output, 0, (void **)&layout, &size);
    CHECK_CA_ERROR_L(coreaudio_error_audiounit, "unable to retrieve audio unit channel layout");

    MP_VERBOSE(ao, "AU channel layout tag: %x (%x)\n",
               layout->mChannelLayoutTag, layout->mChannelBitmap);

    // Save a copy of the raw hardware layout before convert_layout frees it.
    // This is used to configure the spatial mixer output for external speakers.
    hw_layout = talloc_memdup(NULL, layout, size);
    UInt32 hw_layout_size = size;

    layout = convert_layout(layout, &size);
    if (!layout) {
        MP_ERR(ao, "unable to convert channel layout to list format\n");
        goto coreaudio_error_audiounit;
    }

    int hw_channels = (int)layout->mNumberChannelDescriptions;

    for (UInt32 i = 0; i < layout->mNumberChannelDescriptions; i++) {
        MP_VERBOSE(ao, "channel map: %i: %u\n", i,
                   layout->mChannelDescriptions[i].mChannelLabel);
    }

    // Try spatial audio path for multichannel content (5.1 and above)
    struct audiounit_opts *opts = mp_get_config_group(ao, ao->global, &ao_audiounit_conf);
    int spatial_mode = opts->spatial_audio;
    talloc_free(opts);

    if (spatial_mode && !af_fmt_is_spdif(ao->format) && ao->channels.num >= 6) {
        // For spatial audio, request planar float format from mpv
        int orig_format = ao->format;
        ao->format = AF_FORMAT_FLOATP;

        // Determine output type and spatial mixer output channel configuration.
        // For external speakers with multichannel hardware (e.g. HDMI to a TV),
        // configure the spatial mixer to output the hardware's multichannel layout.
        // For headphones and built-in speakers, output stereo for binaural rendering.
        AUSpatialMixerOutputType output_type = get_spatial_output_type();
        int spatial_out_ch;
        AudioChannelLayout *spatial_out_acl;
        UInt32 spatial_out_acl_size;
        AudioChannelLayout stereo_acl = {
            .mChannelLayoutTag = kAudioChannelLayoutTag_Stereo,
        };

        if (output_type == kSpatialMixerOutputType_ExternalSpeakers && hw_channels > 2) {
            spatial_out_ch = hw_channels;
            spatial_out_acl = hw_layout;
            spatial_out_acl_size = hw_layout_size;
        } else {
            spatial_out_ch = 2;
            spatial_out_acl = &stereo_acl;
            spatial_out_acl_size = sizeof(AudioChannelLayout);
        }

        // Try to initialize the spatial mixer
        if (init_spatial_mixer(ao, spatial_mode == 2, output_type,
                               spatial_out_ch, spatial_out_acl, spatial_out_acl_size)) {
            p->spatial_enabled = true;

            // Set RemoteIO input to non-interleaved float matching the spatial mixer
            // output. This allows a direct memcpy in the render callback.
            AudioStreamBasicDescription remoteio_asbd = {
                .mSampleRate       = ao->samplerate,
                .mFormatID         = kAudioFormatLinearPCM,
                .mFormatFlags      = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
                                     | kAudioFormatFlagIsNonInterleaved,
                .mBytesPerPacket   = 4,
                .mFramesPerPacket  = 1,
                .mBytesPerFrame    = 4,
                .mChannelsPerFrame = spatial_out_ch,
                .mBitsPerChannel   = 32,
            };
            size = sizeof(AudioStreamBasicDescription);
            err = AudioUnitSetProperty(p->audio_unit, kAudioUnitProperty_StreamFormat,
                                       kAudioUnitScope_Input, 0, &remoteio_asbd, size);
            CHECK_CA_ERROR_L(coreaudio_error_spatial,
                             "unable to set format on audio unit for spatial output");

            // Set the RemoteIO render callback to pull from the spatial mixer
            AURenderCallbackStruct render_cb = {
                .inputProc       = spatial_output_cb,
                .inputProcRefCon = ao,
            };
            err = AudioUnitSetProperty(p->audio_unit, kAudioUnitProperty_SetRenderCallback,
                                       kAudioUnitScope_Input, 0, &render_cb,
                                       sizeof(AURenderCallbackStruct));
            CHECK_CA_ERROR_L(coreaudio_error_spatial,
                             "unable to set spatial render callback on audio unit");

            // Register for route change notifications.
            // Reload the audio output so the spatial mixer is rebuilt with
            // the correct output type and channel configuration.
            p->route_change_observer = [[NSNotificationCenter defaultCenter]
                addObserverForName:AVAudioSessionRouteChangeNotification
                            object:nil
                             queue:nil
                        usingBlock:^(NSNotification *note) {
                MP_VERBOSE(ao, "audio route changed, requesting ao reload\n");
                ao_request_reload(ao);
            }];

            talloc_free(hw_layout);
            talloc_free(layout);
            return true;
        }

        // Spatial mixer init failed, restore format and fall through
        ao->format = orig_format;
        MP_VERBOSE(ao, "spatial mixer setup failed, falling back to direct output\n");
    }

    talloc_free(hw_layout);
    hw_layout = NULL;

    // Direct output path (stereo or passthrough)
    p->spatial_enabled = false;

    if (af_fmt_is_spdif(ao->format) || instance.outputNumberOfChannels <= 2) {
        ao->channels = (struct mp_chmap)MP_CHMAP_INIT_STEREO;
        MP_VERBOSE(ao, "using stereo output\n");
    } else {
        ao->channels.num = (uint8_t)layout->mNumberChannelDescriptions;
        for (UInt32 i = 0; i < layout->mNumberChannelDescriptions; i++) {
            ao->channels.speaker[i] =
                ca_label_to_mp_speaker_id(layout->mChannelDescriptions[i].mChannelLabel);
        }
        MP_VERBOSE(ao, "using standard channel mapping\n");
    }

    ca_fill_asbd(ao, &asbd);
    size = sizeof(AudioStreamBasicDescription);
    err = AudioUnitSetProperty(p->audio_unit, kAudioUnitProperty_StreamFormat,
                               kAudioUnitScope_Input, 0, &asbd, size);
    CHECK_CA_ERROR_L(coreaudio_error_audiounit,
                     "unable to set the input format on the audio unit");

    AURenderCallbackStruct render_cb = (AURenderCallbackStruct) {
        .inputProc       = render_cb_lpcm,
        .inputProcRefCon = ao,
    };

    err = AudioUnitSetProperty(p->audio_unit, kAudioUnitProperty_SetRenderCallback,
                               kAudioUnitScope_Input, 0, &render_cb,
                               sizeof(AURenderCallbackStruct));
    CHECK_CA_ERROR_L(coreaudio_error_audiounit,
                     "unable to set render callback on audio unit");

    talloc_free(layout);
    return true;

coreaudio_error_spatial:
    AudioUnitUninitialize(p->spatial_mixer);
    AudioComponentInstanceDispose(p->spatial_mixer);
    p->spatial_mixer = NULL;
    p->spatial_enabled = false;
    for (int i = 0; i < SPATIAL_MAX_CH; i++) {
        talloc_free(p->mixer_buf[i]);
        p->mixer_buf[i] = NULL;
    }
    talloc_free(p->spatial_abl);
    p->spatial_abl = NULL;
coreaudio_error_audiounit:
    AudioUnitUninitialize(p->audio_unit);
coreaudio_error_component:
    AudioComponentInstanceDispose(p->audio_unit);
coreaudio_error:
    talloc_free(hw_layout);
    talloc_free(layout);
    return false;
}

static void stop(struct ao *ao)
{
    // struct priv *p = ao->priv;
    // OSStatus err = AudioOutputUnitStop(p->audio_unit);
    // CHECK_CA_WARN("can't stop audio unit");
}

static void start(struct ao *ao)
{
    struct priv *p = ao->priv;
    AVAudioSession *instance = AVAudioSession.sharedInstance;

    p->device_latency = [instance outputLatency];

    OSStatus err = AudioOutputUnitStart(p->audio_unit);
    CHECK_CA_WARN("can't start audio unit");
}

static void uninit(struct ao *ao)
{
    struct priv *p = ao->priv;

    if (p->route_change_observer) {
        [[NSNotificationCenter defaultCenter] removeObserver:p->route_change_observer];
        p->route_change_observer = nil;
    }

    AudioOutputUnitStop(p->audio_unit);

    if (p->spatial_enabled && p->spatial_mixer) {
        AudioUnitUninitialize(p->spatial_mixer);
        AudioComponentInstanceDispose(p->spatial_mixer);
    }

    AudioUnitUninitialize(p->audio_unit);
    AudioComponentInstanceDispose(p->audio_unit);

    for (int i = 0; i < SPATIAL_MAX_CH; i++)
        talloc_free(p->mixer_buf[i]);
    talloc_free(p->spatial_abl);
}

static int init(struct ao *ao)
{
    if (!init_audiounit(ao))
        goto coreaudio_error;

    return CONTROL_OK;

coreaudio_error:
    return CONTROL_ERROR;
}

#define OPT_BASE_STRUCT struct audiounit_opts

static const struct m_sub_options ao_audiounit_conf = {
    .opts = (const struct m_option[]) {
        {"audiounit-spatial-audio", OPT_CHOICE(spatial_audio,
            {"no", 0}, {"yes", 1}, {"head-tracking", 2}),
            .flags = UPDATE_AUDIO},
        {0}
    },
    .defaults = &(const struct audiounit_opts) {
        .spatial_audio = 0,
    },
    .size = sizeof(struct audiounit_opts),
};

const struct ao_driver audio_out_audiounit = {
    .description    = "AudioUnit (iOS)",
    .name           = "audiounit",
    .uninit         = uninit,
    .init           = init,
    .reset          = stop,
    .start          = start,
    .priv_size      = sizeof(struct priv),
    .global_opts    = &ao_audiounit_conf,
};
