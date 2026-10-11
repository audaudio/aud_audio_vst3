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
  // A frame by hand: the length of [body] as 4 bytes little endian, then
  // [body] in UTF-8.
  Uint8List frameOf(String body) {
    final text = utf8.encode(body);
    final header = Uint8List(4);
    ByteData.sublistView(header).setUint32(0, text.length, Endian.little);
    return Uint8List.fromList([...header, ...text]);
  }

  // The messages of [chunks], decoded.
  Future<List<AudShellMessage>> decode(List<Uint8List> chunks) =>
      Stream.fromIterable(chunks).transform(AudShellCodec.decoder()).toList();

  group('AudShellCodec', () {
    group('encode(message)', () {
      test('frames the JSON of the message with its length', () {
        expect(
          AudShellCodec.encode(const AudShellClose()),
          frameOf('{"type":"close"}'),
        );
      });
    });

    group('decoder()', () {
      const messages = [
        AudShellShow(),
        AudShellMeter(peak: 1, rms: 0.5),
        AudShellHide(),
      ];
      final bytes = [
        for (final message in messages) ...AudShellCodec.encode(message),
      ];
      for (final (arrival, chunks) in [
        (
          'one byte at a time',
          [
            for (final byte in bytes) Uint8List.fromList([byte]),
          ],
        ),
        ('all at once', [Uint8List.fromList(bytes)]),
      ]) {
        test('decodes frames that arrive $arrival', () async {
          final decoded = await decode(chunks);
          expect(
            [for (final message in decoded) message.toJson()],
            [for (final message in messages) message.toJson()],
          );
        });
      }

      test('refuses a frame above maxFrame', () {
        final header = Uint8List(4);
        ByteData.sublistView(
          header,
        ).setUint32(0, AudShellCodec.maxFrame + 1, Endian.little);
        expect(
          decode([header]),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              'Shell frame of ${AudShellCodec.maxFrame + 1} bytes',
            ),
          ),
        );
      });

      // The text, the message of the FormatException and its source.
      const missingField = '{"type":"hello","pid":1}';
      const unknownKind = '{"type":"input","kind":"nonsense"}';
      const array = '[{"type":"close"}]';
      for (final (text, body, message, source) in [
        (
          'a missing field',
          missingField,
          'Malformed shell message',
          missingField,
        ),
        (
          'an unknown input kind',
          unknownKind,
          'Malformed shell message',
          unknownKind,
        ),
        ('a JSON array', array, 'No shell message', array),
        ('a JSON string', '"close"', 'No shell message', '"close"'),
        (
          'an unknown type',
          '{"type":"nonsense"}',
          'Unknown shell message',
          {'type': 'nonsense'},
        ),
      ]) {
        test('ends the stream with a FormatException on $text', () {
          expect(
            decode([frameOf(body)]),
            throwsA(
              isA<FormatException>()
                  .having((e) => e.message, 'message', message)
                  .having((e) => e.source, 'source', source),
            ),
          );
        });
      }
    });
  });
}
