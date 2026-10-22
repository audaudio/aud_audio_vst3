// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// A socket pair and raw reads and writes for the tests of the transport
// over an inherited socket.

import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:test/test.dart';

final _libc = DynamicLibrary.process();
final _socketpair = _libc
    .lookupFunction<
      Int32 Function(Int32, Int32, Int32, Pointer<Int32>),
      int Function(int, int, int, Pointer<Int32>)
    >('socketpair');
final _read = _libc
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
      int Function(int, Pointer<Uint8>, int)
    >('read');
final _write = _libc
    .lookupFunction<
      IntPtr Function(Int32, Pointer<Uint8>, IntPtr),
      int Function(int, Pointer<Uint8>, int)
    >('write');

/// Closes a file descriptor.
final closeFd = _libc.lookupFunction<Int32 Function(Int32), int Function(int)>(
  'close',
);

/// Makes `to` a second descriptor of the file of `from`, as dup2(2) does;
/// returns `to`, or -1.
final dupFd = _libc
    .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
      'dup2',
    );

/// A connected pair of Unix domain sockets: the plugin's end and the
/// editor's.
(int, int) socketPair() {
  final fds = calloc<Int32>(2);
  try {
    expect(_socketpair(1, 1, 0, fds), 0); // AF_UNIX, SOCK_STREAM
    return (fds[0], fds[1]);
  } finally {
    calloc.free(fds);
  }
}

/// Writes all of [bytes] to [fd].
void writeAll(int fd, List<int> bytes) {
  final buffer = malloc<Uint8>(bytes.length);
  buffer.asTypedList(bytes.length).setAll(0, bytes);
  expect(_write(fd, buffer, bytes.length), bytes.length);
  malloc.free(buffer);
}

/// What [fd] holds now, at most 64 KiB.
List<int> readSome(int fd) {
  final buffer = malloc<Uint8>(65536);
  final n = _read(fd, buffer, 65536);
  final bytes = List<int>.of(buffer.asTypedList(n < 0 ? 0 : n));
  malloc.free(buffer);
  return bytes;
}
