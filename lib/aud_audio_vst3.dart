// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

/// The VST3 shell of the Audanika Audio Engine. The plugin itself is C++
/// (`src/`, built by `scripts/build-plugin.js`); this library is the Dart
/// end of the shell protocol between the plugin and its editor process:
/// the messages, their framing and the socket client (ticket 24).
library;

export 'src/aud_audio_vst3_version.dart';
export 'src/aud_shell_client.dart';
export 'src/aud_shell_codec.dart';
export 'src/aud_shell_message.dart';
