// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

// #############################################################################
/// A byte stream over a socket the process inherited as file descriptor
/// [fd] (ticket 37): the plugin hands its sandboxed editor one end of a
/// socket pair when it starts it, so that the editor reaches the plugin
/// without a file anywhere. `dart:io` opens no socket by its descriptor, so
/// an isolate of its own reads it through `read(2)` and [add] writes
/// through `write(2)`.
class AudShellFd {
  // The POSIX parts run on macOS and Linux only; Windows refuses in
  // open() (ticket 38).
  // coverage:ignore-start
  AudShellFd._(this.fd, this._port) {
    _port.listen((message) {
      if (message is TransferableTypedData) {
        _input.add(message.materialize().asUint8List());
        return;
      }
      // The reader ended: the other end closed or the socket failed.
      _port.close();
      unawaited(_input.close());
    });
  }

  // ...........................................................................
  /// Starts reading [fd]; throws an [UnsupportedError] on Windows, which
  /// hands a process no socket as a file descriptor (ticket 38).
  static Future<AudShellFd> open(int fd) async {
    // coverage:ignore-end
    if (Platform.isWindows) {
      throw UnsupportedError(
        'AudShellFd reads an inherited POSIX socket; Windows has none',
      );
    }
    // coverage:ignore-start
    final port = ReceivePort();
    await Isolate.spawn(_read, (fd, port.sendPort));
    return AudShellFd._(fd, port);
  }

  /// The file descriptor.
  final int fd;

  final ReceivePort _port;
  final _input = StreamController<Uint8List>(sync: true);
  bool _closed = false;
  Future<void>? _closing;

  // ...........................................................................
  /// What the other end writes; ends when it closes.
  Stream<Uint8List> get input => _input.stream;

  // ...........................................................................
  /// Writes [bytes] completely; nothing after [close] or a failed write.
  void add(List<int> bytes) {
    if (_closed || bytes.isEmpty) return;
    final buffer = malloc<Uint8>(bytes.length);
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      var written = 0;
      while (written < bytes.length) {
        final n = _write(fd, buffer + written, bytes.length - written);
        if (n > 0) {
          written += n;
        } else if (n < 0 && _errno() == _eintr) {
          continue; // coverage:ignore-line, a signal during write(2)
        } else {
          _closed = true;
          return;
        }
      }
    } finally {
      malloc.free(buffer);
    }
  }

  // ...........................................................................
  /// Ends both directions: the reader sees the end, the descriptor closes.
  /// Every call returns the future of the first, so the descriptor closes
  /// once: a second close(2) could close another file that took its number.
  Future<void> close() => _closing ??= _end();

  Future<void> _end() async {
    _closed = true;
    _shutdown(fd, _shutReadWrite);
    await _input.done.timeout(const Duration(seconds: 1), onTimeout: () {});
    _close(fd);
  }
}

// .............................................................................
// The reader isolate: read(2) until the end, each chunk to [port].
void _read((int, SendPort) args) {
  final (fd, port) = args;
  const size = 65536;
  final buffer = malloc<Uint8>(size);
  try {
    for (;;) {
      final n = _readFd(fd, buffer, size);
      if (n > 0) {
        port.send(TransferableTypedData.fromList([buffer.asTypedList(n)]));
        continue;
      }
      if (n < 0 && _errno() == _eintr) continue;
      break;
    }
  } finally {
    malloc.free(buffer);
    port.send(null);
  }
}

const _eintr = 4;
const _shutReadWrite = 2;

final _libc = DynamicLibrary.process();

final _readFd = _libc
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
      int Function(int, Pointer<Uint8>, int)
    >('read');

final _write = _libc
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
      int Function(int, Pointer<Uint8>, int)
    >('write');

final _shutdown = _libc
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
      'shutdown',
    );

final _close = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
  'close',
);

final _errnoLocation = _libc
    .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
      Platform.isMacOS || Platform.isIOS ? '__error' : '__errno_location',
    );

int _errno() => _errnoLocation().value;
// coverage:ignore-end
