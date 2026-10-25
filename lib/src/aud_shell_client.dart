// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aud_audio_plugin/aud_audio_plugin.dart';

import 'aud_shell_fd.dart';

// #############################################################################
/// The editor's end of the shell protocol: exchanges [AudShellMessage]s
/// with the plugin, over the socket pair whose end the plugin handed the
/// editor as a file descriptor when it started it ([AudShellClient.fromFd],
/// ticket 37), or over a Unix domain socket the plugin listens on
/// ([AudShellClient.connect], the spike of ticket 24). It introduces itself
/// with the token the plugin gave it. The stream ends when the plugin ends
/// the connection - the editor then quits.
class AudShellClient {
  AudShellClient._(Stream<Uint8List> input, this._write, this._close) {
    _subscription = input
        .transform(AudShellCodec.decoder())
        .listen(
          _messages.add,
          onError: _messages.addError,
          onDone: () => unawaited(_messages.close()),
        );
  }

  // ...........................................................................
  /// Connects to the socket at [path] and sends [hello].
  static Future<AudShellClient> connect(
    String path,
    AudShellHello hello,
  ) async {
    final socket = await Socket.connect(
      InternetAddress(path, type: InternetAddressType.unix),
      0,
    );
    final client = AudShellClient._(socket, socket.add, () async {
      socket.destroy();
    });
    client.send(hello);
    return client;
  }

  // ...........................................................................
  /// Talks over the inherited socket [fd] and sends [hello].
  // A POSIX socket only, which Windows refuses (ticket 38).
  // coverage:ignore-start
  static Future<AudShellClient> fromFd(int fd, AudShellHello hello) async {
    final channel = await AudShellFd.open(fd);
    final client = AudShellClient._(channel.input, channel.add, channel.close);
    client.send(hello);
    return client;
  }
  // coverage:ignore-end

  final void Function(List<int> bytes) _write;
  final Future<void> Function() _close;
  final _messages = StreamController<AudShellMessage>.broadcast(sync: true);
  late final StreamSubscription<AudShellMessage> _subscription;

  /// The messages of the plugin.
  Stream<AudShellMessage> get messages => _messages.stream;

  // ...........................................................................
  /// Sends [message].
  void send(AudShellMessage message) => _write(AudShellCodec.encode(message));

  // ...........................................................................
  /// Closes the connection in both directions at once.
  Future<void> close() async {
    // Ended first: the decoder waits for the input and ends with it.
    await _close();
    await _subscription.cancel();
    if (!_messages.isClosed) await _messages.close();
  }
}
