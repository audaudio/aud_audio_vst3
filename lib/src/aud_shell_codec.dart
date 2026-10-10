// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'aud_shell_message.dart';

// #############################################################################
/// The framing of the shell protocol: a 4-byte little-endian length, then
/// that many bytes of UTF-8 JSON. The plugin's C++ side
/// (src/aud_vst3_socket.cpp) frames the same way.
abstract final class AudShellCodec {
  /// The largest frame either side accepts.
  static const int maxFrame = 16 << 20;

  // ...........................................................................
  /// The frame of [message].
  static Uint8List encode(AudShellMessage message) {
    final body = utf8.encode(jsonEncode(message.toJson()));
    final frame = Uint8List(4 + body.length);
    ByteData.sublistView(frame).setUint32(0, body.length, Endian.little);
    frame.setRange(4, frame.length, body);
    return frame;
  }

  // ...........................................................................
  /// Splits a byte stream into messages; bytes may arrive in any chunks.
  /// A frame above [maxFrame] or text that is no message ends the stream
  /// with a [FormatException].
  static StreamTransformer<Uint8List, AudShellMessage> decoder() =>
      StreamTransformer<Uint8List, AudShellMessage>.fromBind(_decode);

  static Stream<AudShellMessage> _decode(Stream<Uint8List> bytes) async* {
    final buffer = BytesBuilder(copy: false);
    var pending = Uint8List(0);
    await for (final chunk in bytes) {
      buffer
        ..add(pending)
        ..add(chunk);
      pending = buffer.takeBytes();
      var offset = 0;
      while (pending.length - offset >= 4) {
        final length = ByteData.sublistView(
          pending,
          offset,
          offset + 4,
        ).getUint32(0, Endian.little);
        if (length > maxFrame) {
          throw FormatException('Shell frame of $length bytes');
        }
        if (pending.length - offset - 4 < length) break;
        final body = utf8.decode(
          Uint8List.sublistView(pending, offset + 4, offset + 4 + length),
        );
        offset += 4 + length;
        yield AudShellMessage.fromJson(
          jsonDecode(body) as Map<String, Object?>,
        );
      }
      pending = Uint8List.sublistView(pending, offset);
    }
  }
}
