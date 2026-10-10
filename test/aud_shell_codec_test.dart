// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:convert';
import 'dart:typed_data';

import 'package:aud_audio_vst3/aud_audio_vst3.dart';
import 'package:test/test.dart';

void main() {
  group('AudShellCodec', () {
    test('frames a message with its length', () {
      final frame = AudShellCodec.encode(const AudShellClose());
      final body = utf8.encode('{"type":"close"}');
      expect(
        ByteData.sublistView(frame).getUint32(0, Endian.little),
        body.length,
      );
      expect(frame.sublist(4), body);
    });

    test('decodes frames that arrive in any chunks', () async {
      final bytes = <int>[
        ...AudShellCodec.encode(const AudShellShow()),
        ...AudShellCodec.encode(const AudShellMeter(peak: 1, rms: 0.5)),
        ...AudShellCodec.encode(const AudShellHide()),
      ];
      // One byte at a time, then everything at once.
      for (final chunks in [
        [
          for (final b in bytes) Uint8List.fromList([b]),
        ],
        [Uint8List.fromList(bytes)],
      ]) {
        final messages = await Stream.fromIterable(
          chunks,
        ).transform(AudShellCodec.decoder()).toList();
        expect(messages.map((m) => m.runtimeType), [
          AudShellShow,
          AudShellMeter,
          AudShellHide,
        ]);
      }
    });

    test('refuses a frame that is too large', () {
      final header = Uint8List(4);
      ByteData.sublistView(
        header,
      ).setUint32(0, AudShellCodec.maxFrame + 1, Endian.little);
      expect(
        Stream.value(header).transform(AudShellCodec.decoder()).toList(),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
