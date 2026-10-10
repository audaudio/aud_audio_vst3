// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:io';

import 'aud_shell_codec.dart';
import 'aud_shell_message.dart';

// #############################################################################
/// The editor's end of the shell protocol: connects to the Unix domain
/// socket the plugin listens on, introduces itself with the token and
/// exchanges [AudShellMessage]s. The stream ends when the plugin closes the
/// socket - the editor then quits.
class AudShellClient {
  AudShellClient._(this._socket) {
    _subscription = _socket
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
    final client = AudShellClient._(socket);
    client.send(hello);
    return client;
  }

  final Socket _socket;
  final _messages = StreamController<AudShellMessage>.broadcast(sync: true);
  late final StreamSubscription<AudShellMessage> _subscription;

  /// The messages of the plugin.
  Stream<AudShellMessage> get messages => _messages.stream;

  // ...........................................................................
  /// Sends [message].
  void send(AudShellMessage message) =>
      _socket.add(AudShellCodec.encode(message));

  // ...........................................................................
  /// Closes the connection in both directions at once.
  Future<void> close() async {
    // Destroyed first: the decoder waits for the socket and ends with it.
    _socket.destroy();
    await _subscription.cancel();
    if (!_messages.isClosed) await _messages.close();
  }
}
