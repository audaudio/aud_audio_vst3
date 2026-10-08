import 'package:test/test.dart';

import 'package:aud_audio_vst3/aud_audio_vst3.dart';

void main() {
  test('invoke native function', () {
    expect(sum(24, 18), 42);
  });

  test('invoke async native callback', () async {
    expect(await sumAsync(24, 18), 42);
  });
}
