// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

import 'dart:ffi';

import 'package:ffi/ffi.dart';

// #############################################################################
final class _Timebase extends Struct {
  @Uint32()
  external int numer;

  @Uint32()
  external int denom;
}

// #############################################################################
/// mach_absolute_time in nanoseconds: the clock of the plugin's probes, the
/// same in every process of the machine.
abstract final class AudMachClock {
  static final DynamicLibrary _process = DynamicLibrary.process();

  static final int Function() _absolute = _process
      .lookupFunction<Uint64 Function(), int Function()>('mach_absolute_time');

  static final (int, int) _timebase = () {
    final info = calloc<_Timebase>();
    _process.lookupFunction<
      Int32 Function(Pointer<_Timebase>),
      int Function(Pointer<_Timebase>)
    >('mach_timebase_info')(info);
    final result = (info.ref.numer, info.ref.denom);
    calloc.free(info);
    return result;
  }();

  // ...........................................................................
  /// The current time in nanoseconds.
  static int nowNs() => _absolute() * _timebase.$1 ~/ _timebase.$2;
}
