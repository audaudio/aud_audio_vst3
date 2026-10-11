// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The parts of the shell protocol's messages (lib/src/aud_shell_message.dart)
// that every Flutter editor of the spike gets alike (ticket 24): the editor
// process of variants A, S and F over the socket, the in-process editor of
// variant B over its method channel.

#ifndef AUD_VST3_SHELL_HPP
#define AUD_VST3_SHELL_HPP

#include "aud_json.hpp"

namespace aud_vst3 {

class Plugin;

// #############################################################################
// The parameters of `plugin` as the welcome message lists them: one
// AudShellParam with the current value for each parameter of the document.
aud::Json welcomeParams(Plugin& plugin);

}  // namespace aud_vst3

#endif  // AUD_VST3_SHELL_HPP
