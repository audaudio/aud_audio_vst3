// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aud_audio_core/aud_audio_core.dart';
import 'package:aud_audio_vst3/aud_audio_vst3.dart';
import 'package:test/test.dart';

import 'socket_pair.dart';

void main() {
  group('AudShellClient', () {
    const hello = AudShellHello(token: 'secret', instance: 3, pid: 9);
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

    // Connects a client; returns it, the plugin's end of the socket and
    // what the plugin receives.
    Future<(AudShellClient, Socket, StreamIterator<AudShellMessage>)>
    connect() async {
      final accepted = server.first;
      final client = await AudShellClient.connect(path, hello);
      final plugin = await accepted;
      final received = StreamIterator(
        plugin.transform(AudShellCodec.decoder()),
      );
      return (client, plugin, received);
    }

    group('connect(path, hello)', () {
      test('introduces the editor with the hello', () async {
        final (client, plugin, received) = await connect();
        expect(await received.moveNext(), isTrue);
        expect(received.current.toJson(), hello.toJson());
        await client.close();
        await received.cancel();
      });
    });

    group('send(message)', () {
      test('frames the message to the plugin', () async {
        final (client, plugin, received) = await connect();
        client.send(const AudShellCursor('basic'));
        final messages = [
          for (var i = 0; i < 2 && await received.moveNext(); ++i)
            received.current.toJson(),
        ];
        expect(messages, [
          hello.toJson(),
          const AudShellCursor('basic').toJson(),
        ]);
        await client.close();
        await received.cancel();
      });
    });

    group('messages', () {
      test('carries the plugin messages until it closes the socket', () async {
        final (client, plugin, received) = await connect();
        final fromPlugin = <AudShellMessage>[];
        final done = Completer<void>();
        client.messages.listen(fromPlugin.add, onDone: done.complete);
        const param = AudShellParamValue(id: 7, value: 1);
        plugin.add(AudShellCodec.encode(param));
        await plugin.close();
        await done.future;
        expect([for (final m in fromPlugin) m.toJson()], [param.toJson()]);
        await client.close();
        await received.cancel();
      });

      test('reports a frame above maxFrame as an error', () async {
        final (client, plugin, received) = await connect();
        final error = Completer<Object>();
        client.messages.listen((_) {}, onError: error.complete);
        final header = Uint8List(4);
        ByteData.sublistView(header).setUint32(0, 0xFFFFFFFF, Endian.little);
        plugin.add(header);
        expect(
          await error.future,
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'Shell frame of 4294967295 bytes',
          ),
        );
        await client.close();
        await received.cancel();
        plugin.destroy();
      });
    });
  });

  group('AudShellClient.fromFd', () {
    test('sends the hello and receives framed messages', () async {
      final (plugin, editor) = socketPair();
      final client = await AudShellClient.fromFd(
        editor,
        const AudShellHello(token: 'abc', instance: 3, pid: 42),
      );
      final hello = AudShellCodec.encode(
        const AudShellHello(token: 'abc', instance: 3, pid: 42),
      );
      expect(readSome(plugin), hello);
      final message = client.messages.first;
      writeAll(plugin, AudShellCodec.encode(const AudShellShow(instance: 3)));
      expect(
        await message.timeout(const Duration(seconds: 5)),
        isA<AudShellShow>(),
      );
      client.send(
        const AudShellCommand(
          AudSetParamCommand(node: 1, paramIndex: 0, value: 2),
          instance: 3,
        ),
      );
      expect(readSome(plugin), isNotEmpty);
      await client.close();
      closeFd(plugin);
    });
    // A POSIX socket pair carries these tests (ticket 38).
  }, testOn: '!windows');
}
