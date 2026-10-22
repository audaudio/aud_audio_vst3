// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The plugin factory: one instrument class per bundle, named and identified
// by the plugin.json of the app that built it (aud_vst3_config.hpp).

#include "public.sdk/source/main/pluginfactory.h"

#include "aud_vst3_config.hpp"
#include "aud_vst3_plugin.hpp"

using Steinberg::PClassInfo;

// #############################################################################
// The factory of the bundle.
BEGIN_FACTORY_DEF(AUD_VST3_VENDOR, AUD_VST3_URL, AUD_VST3_EMAIL)

DEF_CLASS2(INLINE_UID(AUD_VST3_CID0, AUD_VST3_CID1, AUD_VST3_CID2,
                      AUD_VST3_CID3),
           PClassInfo::kManyInstances, kVstAudioEffectClass, AUD_VST3_NAME,
           0, AUD_VST3_SUBCATEGORIES, AUD_VST3_VERSION, kVstVersionString,
           aud_vst3::Plugin::createInstance)

END_FACTORY
