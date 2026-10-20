// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Builds and runs the native unit tests of test/native (tickets 24 and 37) with the
// compile settings of scripts/build-plugin.js: every test is linked with the
// sources it covers into an executable under .dart_tool/vst3-build/test,
// which runs its tests and reports the failures. Exits with 1 when a test
// fails or does not build.
//
//   node scripts/test-native.js           every test
//   node scripts/test-native.js socket    the tests whose file name holds it

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const {
  root,
  sdkDir,
  buildDir,
  frameworks,
  targetFlags,
  run,
  packageSrcOf,
  sdkSources,
  hashOf,
  compilerOf,
  baseFlags,
  headersHash,
  compileAll,
  cppIn,
} = require('./build-plugin.js');

const testDir = path.join(root, 'test', 'native');

// The tests: the sources each covers, whether it needs the graph engine and
// the vendored SDK.
const tests = [
  {
    file: 'aud_vst3_midi_test.cpp',
    sources: ['src/aud_vst3_midi.cpp'],
  },
  {
    file: 'aud_vst3_param_test.cpp',
    sources: ['src/aud_vst3_param.cpp'],
    sdk: true,
  },
  {
    file: 'aud_vst3_settings_test.cpp',
    sources: ['src/aud_vst3_settings.cpp'],
    graph: true,
  },
  {
    file: 'aud_vst3_socket_test.cpp',
    sources: ['src/aud_vst3_socket.cpp'],
    graphFiles: ['aud_json.cpp'],
  },
  {
    file: 'aud_vst3_transport_test.cpp',
    sources: ['src/aud_vst3_transport.cpp'],
  },
];

// The vendored SDK as a static library, from which the linker takes only
// what a test's sources need.
async function sdkLibrary(compiler, flags, objDir, headers) {
  const objects = await compileAll(compiler, flags, sdkSources(), objDir, headers);
  const library = path.join(objDir, `vst3sdk-${hashOf(objects)}.a`);
  if (!fs.existsSync(library)) {
    run('libtool', ['-static', '-no_warning_for_no_symbols', '-o', library, ...objects]);
  }
  return library;
}

// Builds the executable of `test` and returns its path.
async function buildTest(test) {
  const options = { rtsan: false, watchdog: false };
  const compiler = compilerOf(options);
  const packageSrc = packageSrcOf(path.join(root, '.dart_tool', 'package_config.json'));
  const dirs = { graph: packageSrc('aud_audio_graph'), core: packageSrc('aud_audio_core') };
  const flags = baseFlags(options, dirs);
  const objDir = path.join(buildDir, 'test');
  const headers = headersHash([sdkDir, dirs.graph, dirs.core, path.join(root, 'src'), testDir]);
  const files = [
    path.join(testDir, test.file),
    ...test.sources.map((file) => path.join(root, file)),
    ...(test.graph ? cppIn(dirs.graph) : []),
    ...(test.graphFiles ?? []).map((file) => path.join(dirs.graph, file)),
  ];
  const objects = await compileAll(compiler, flags, files, objDir, headers);
  const libraries = test.sdk ? [await sdkLibrary(compiler, flags, objDir, headers)] : [];
  const binary = path.join(
    objDir,
    `${path.basename(test.file, '.cpp')}-${hashOf([...objects, ...libraries])}`,
  );
  if (!fs.existsSync(binary)) {
    run(compiler, [
      ...targetFlags,
      '-o',
      binary,
      ...objects,
      ...libraries,
      ...frameworks.flatMap((framework) => ['-framework', framework]),
    ]);
  }
  return binary;
}

async function main() {
  const filter = process.argv[2] ?? '';
  const selected = tests.filter((test) => test.file.includes(filter));
  if (selected.length === 0) {
    throw new Error(`No native test matches ${filter}`);
  }
  const failed = [];
  for (const test of selected) {
    const name = path.basename(test.file, '.cpp');
    console.log(`${name}:`);
    const binary = await buildTest(test);
    const result = spawnSync(binary, [], { stdio: 'inherit' });
    if (result.status !== 0) failed.push(name);
  }
  if (failed.length > 0) throw new Error(`Failed: ${failed.join(', ')}`);
  console.log('All native tests passed');
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
