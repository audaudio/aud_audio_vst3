// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The plugin factory: one class per bundle. Variant, flavor, hygiene and
// the check a build runs under (watchdog, RealtimeSanitizer) make the class
// id and the name, so every bundle of the spike coexists in one host.

#include "aud_vst3_config.hpp"
#include "aud_vst3_plugin.hpp"
#include "public.sdk/source/main/pluginfactory.h"

#define AUD_VST3_STRINGIFY2(x) #x
#define AUD_VST3_STRINGIFY(x) AUD_VST3_STRINGIFY2(x)

#ifdef AUD_VST3_NO_HYGIENE
#define AUD_VST3_HYGIENE_ID 0u
#define AUD_VST3_HYGIENE_NAME " (no hygiene)"
#else
#define AUD_VST3_HYGIENE_ID 1u
#define AUD_VST3_HYGIENE_NAME ""
#endif

#if AUD_VST3_RTSAN
#define AUD_VST3_CHECK_ID 0x20u
#define AUD_VST3_CHECK_NAME " (rtsan)"
#elif defined(AUD_GRAPH_WATCHDOG)
#define AUD_VST3_CHECK_ID 0x10u
#define AUD_VST3_CHECK_NAME " (watchdog)"
#else
#define AUD_VST3_CHECK_ID 0u
#define AUD_VST3_CHECK_NAME ""
#endif

#if AUD_VST3_VARIANT == 'A'
#define AUD_VST3_VARIANT_NAME "A"
#elif AUD_VST3_VARIANT == 'B'
#define AUD_VST3_VARIANT_NAME "B"
#elif AUD_VST3_VARIANT == 'C'
#define AUD_VST3_VARIANT_NAME "C"
#elif AUD_VST3_VARIANT == 'F'
#define AUD_VST3_VARIANT_NAME "F"
#elif AUD_VST3_VARIANT == 'S'
#define AUD_VST3_VARIANT_NAME "S"
#else
#define AUD_VST3_VARIANT_NAME "D"
#endif

#define AUD_VST3_NAME                                            \
  "Aud Spike " AUD_VST3_VARIANT_NAME AUD_VST3_STRINGIFY(        \
      AUD_VST3_FLAVOR) AUD_VST3_HYGIENE_NAME AUD_VST3_CHECK_NAME

BEGIN_FACTORY_DEF("Audanika", "https://github.com/audaudio/aud_audio_vst3",
                  "mailto:info@audanika.com")

DEF_CLASS2(INLINE_UID(0x41554433u, 0x5350494Bu,
                      (static_cast<Steinberg::uint32>(AUD_VST3_VARIANT) << 8) |
                          static_cast<Steinberg::uint32>(AUD_VST3_FLAVOR),
                      AUD_VST3_HYGIENE_ID | AUD_VST3_CHECK_ID),
           PClassInfo::kManyInstances, kVstAudioEffectClass, AUD_VST3_NAME,
           0, "Instrument|Synth", AUD_VST3_VERSION, kVstVersionString,
           aud_vst3::Plugin::createInstance)

END_FACTORY
