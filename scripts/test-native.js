// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Builds and runs the native unit tests of test/native (ticket 24) with the
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
  engineDirs,
  sdkSources,
  hashOf,
  compilerOf,
  flagsOf,
  headersHash,
  compileAll,
} = require('./build-plugin.js');

const testDir = path.join(root, 'test', 'native');

// The tests: the sources each covers, the graph sources and whether the
// vendored SDK those need, and the engine flavors it runs in.
const tests = [
  {
    file: 'aud_vst3_param_test.cpp',
    sources: ['src/aud_vst3_param.cpp'],
    sdk: true,
  },
  {
    file: 'aud_vst3_skew_test.cpp',
    sources: ['src/aud_vst3_skew.cpp'],
    flavors: [1, 2],
  },
  {
    file: 'aud_vst3_socket_test.cpp',
    sources: ['src/aud_vst3_socket.cpp'],
    graph: ['aud_json.cpp'],
  },
];

// The vendored SDK as a static library, from which the linker takes only
// what a test's sources need.
async function sdkLibrary(compiler, flags, objDir, headers) {
  const objects = await compileAll(
    compiler,
    flags,
    sdkSources(),
    objDir,
    headers,
  );
  const library = path.join(objDir, `vst3sdk-${hashOf(objects)}.a`);
  if (!fs.existsSync(library)) {
    run('libtool', [
      '-static',
      '-no_warning_for_no_symbols',
      '-o',
      library,
      ...objects,
    ]);
  }
  return library;
}

// Builds the executable of `test` for `flavor` and returns its path. The
// engine's headers are those of flavor 1: only the skew test runs in
// flavor 2, and it includes none of them.
async function buildTest(test, flavor) {
  const options = { flavor, hygiene: true, rtsan: false, watchdog: false };
  const compiler = compilerOf(options);
  const dirs = engineDirs(1);
  const flags = flagsOf(options, 'D', dirs, 'Flutter');
  const objDir = path.join(buildDir, 'test', `flavor${flavor}`);
  const headers = headersHash([
    sdkDir,
    dirs.graph,
    dirs.core,
    path.join(root, 'src'),
    testDir,
  ]);
  const files = [
    path.join(testDir, test.file),
    ...test.sources.map((file) => path.join(root, file)),
    ...(test.graph ?? []).map((file) => path.join(dirs.graph, file)),
  ];
  const objects = await compileAll(compiler, flags, files, objDir, headers);
  const libraries = test.sdk
    ? [await sdkLibrary(compiler, flags, objDir, headers)]
    : [];
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
    for (const flavor of test.flavors ?? [1]) {
      const name = `${path.basename(test.file, '.cpp')} (flavor ${flavor})`;
      console.log(`${name}:`);
      const binary = await buildTest(test, flavor);
      const result = spawnSync(binary, [], { stdio: 'inherit' });
      if (result.status !== 0) failed.push(name);
    }
  }
  if (failed.length > 0) throw new Error(`Failed: ${failed.join(', ')}`);
  console.log('All native tests passed');
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
