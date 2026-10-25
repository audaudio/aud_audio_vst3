// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:async';
import 'package:aud_audio_vst3/aud_audio_vst3.dart';
import 'package:test/test.dart';

import 'socket_pair.dart';

void main() {
  group('AudShellFd', () {
    test('reads what the other end writes and ends with it', () async {
      final (plugin, editor) = socketPair();
      final channel = await AudShellFd.open(editor);
      final received = <int>[];
      final done = Completer<void>();
      channel.input.listen(received.addAll, onDone: done.complete);
      writeAll(plugin, [1, 2, 3]);
      writeAll(plugin, [4]);
      closeFd(plugin);
      await done.future.timeout(const Duration(seconds: 5));
      expect(received, [1, 2, 3, 4]);
      await channel.close();
    });

    test('writes to the other end; close ends the reader', () async {
      final (plugin, editor) = socketPair();
      final channel = await AudShellFd.open(editor);
      final done = Completer<void>();
      channel.input.listen((_) {}, onDone: done.complete);
      channel.add([9, 8, 7]);
      expect(readSome(plugin), [9, 8, 7]);
      await channel.close();
      await done.future.timeout(const Duration(seconds: 5));
      expect(readSome(plugin), isEmpty);
      channel.add([1]);
      closeFd(plugin);
    });

    test('stops writing when the other end is gone', () async {
      final (plugin, editor) = socketPair();
      final channel = await AudShellFd.open(editor);
      final done = Completer<void>();
      channel.input.listen((_) {}, onDone: done.complete);
      closeFd(plugin);
      await done.future.timeout(const Duration(seconds: 5));
      // write(2) fails with EPIPE; the channel writes nothing after it.
      channel.add([1]);
      channel.add([2]);
      await channel.close();
    });

    test('closes the descriptor once, however often it is called', () async {
      final (plugin, editor) = socketPair();
      final (other, peer) = socketPair();
      final channel = await AudShellFd.open(editor);
      channel.input.listen((_) {});
      final first = channel.close();
      final second = channel.close();
      await first;
      // Another socket takes the closed number, as the next file opened may.
      expect(dupFd(peer, editor), editor);
      await second;
      await channel.close();
      writeAll(editor, [5]);
      expect(readSome(other), [5]);
      for (final fd in [plugin, editor, other, peer]) {
        closeFd(fd);
      }
    });
    // A POSIX socket pair carries these tests (ticket 38).
  }, testOn: '!windows');

  test('AudShellFd.open(fd) refuses on Windows', () {
    expect(AudShellFd.open(3, windows: true), throwsUnsupportedError);
  });

  test('AudShellFd.open(fd) refuses on Windows itself', () {
    expect(AudShellFd.open(3), throwsUnsupportedError);
  }, testOn: 'windows');
}
