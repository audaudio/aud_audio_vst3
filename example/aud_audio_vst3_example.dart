// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// The shell protocol in one process: a stand-in for the plugin listens on a
// Unix domain socket, the editor's client connects, introduces itself and
// sends a parameter edit as an AudCommand. The real plugin is the C++ of
// src/ (scripts/build-plugin.js), the real editor the app in editor/.

import 'dart:io';

import 'package:aud_audio_core/aud_audio_core.dart';
import 'package:aud_audio_vst3/aud_audio_vst3.dart';

Future<void> main() async {
  final dir = Directory.systemTemp.createTempSync('aud_vst3_example_');
  final path = '${dir.path}/editor.sock';
  final plugin = await ServerSocket.bind(
    InternetAddress(path, type: InternetAddressType.unix),
    0,
  );
  final connections = <Socket>[];
  plugin.listen((socket) {
    connections.add(socket);
    socket.transform(AudShellCodec.decoder()).listen((message) {
      stdout.writeln('plugin received $message');
      if (message is AudShellHello) {
        socket.add(
          AudShellCodec.encode(
            const AudShellWelcome(
              instance: 1,
              name: 'example',
              params: [],
              width: 620,
              height: 220,
              scale: 2,
            ),
          ),
        );
      }
    });
  });

  final editor = await AudShellClient.connect(
    path,
    AudShellHello(token: 'example', instance: 1, pid: pid),
  );
  final welcome = await editor.messages.first;
  stdout.writeln('editor received $welcome');
  editor.send(
    const AudShellCommand(
      AudSetParamCommand(node: 1, paramIndex: 0, value: 440),
    ),
  );
  await Future<void>.delayed(const Duration(milliseconds: 100));
  await editor.close();
  for (final socket in connections) {
    socket.destroy();
  }
  await plugin.close();
  dir.deleteSync(recursive: true);
}
