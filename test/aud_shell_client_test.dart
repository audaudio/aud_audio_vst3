// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aud_audio_vst3/aud_audio_vst3.dart';
import 'package:test/test.dart';

void main() {
  group('AudShellClient', () {
    late Directory dir;
    late ServerSocket server;
    late String path;

    setUp(() async {
      dir = Directory.systemTemp.createTempSync('aud_shell_');
      path = '${dir.path}/s';
      server = await ServerSocket.bind(
        InternetAddress(path, type: InternetAddressType.unix),
        0,
      );
    });

    tearDown(() async {
      await server.close();
      dir.deleteSync(recursive: true);
    });

    test('says hello and exchanges messages', () async {
      final accepted = server.first;
      final client = await AudShellClient.connect(
        path,
        const AudShellHello(token: 'secret', instance: 3, pid: 9),
      );
      final plugin = await accepted;
      final received = plugin.transform(AudShellCodec.decoder());
      final fromEditor = StreamIterator(received);
      expect(await fromEditor.moveNext(), isTrue);
      expect((fromEditor.current as AudShellHello).token, 'secret');

      final fromPlugin = <AudShellMessage>[];
      final done = Completer<void>();
      client.messages.listen(fromPlugin.add, onDone: done.complete);
      plugin.add(AudShellCodec.encode(const AudShellMeter(peak: 1, rms: 0)));
      client.send(const AudShellCursor('basic'));
      expect(await fromEditor.moveNext(), isTrue);
      expect((fromEditor.current as AudShellCursor).kind, 'basic');
      await plugin.close();
      await done.future;
      expect(fromPlugin.single, isA<AudShellMeter>());
      await client.close();
      await fromEditor.cancel();
    });

    test('reports a broken stream', () async {
      final accepted = server.first;
      final client = await AudShellClient.connect(
        path,
        const AudShellHello(token: 't', instance: 1, pid: 1),
      );
      final plugin = await accepted;
      final error = Completer<Object>();
      client.messages.listen((_) {}, onError: error.complete);
      final header = Uint8List(4);
      ByteData.sublistView(header).setUint32(0, 0xFFFFFFFF, Endian.little);
      plugin.add(header);
      expect(await error.future, isA<FormatException>());
      await client.close();
      plugin.destroy();
    });
  });
}
