// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Builds the test host test/host/aud_vst3_host.mm with the hosting classes
// of the vendored SDK and runs it on a plugin bundle (ticket 37): every
// preset sounds, program list, MIDI mapping, state and realtime blocks, and
// with --editor the editor's frames and notes.
// Objects and the binary are cached under .dart_tool/vst3-build/host.
//
//   node scripts/host.js                       the example plugin, built first
//   node scripts/host.js <bundle.vst3> [--wav <dir>] [--presets n]
//     [--realtime-seconds s] [--editor s [--snapshot <png>] [--click x,y]]

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const {
  root,
  sdkDir,
  buildDir,
  targetFlags,
  run,
  hashOf,
  compileAll,
  headersHash,
  build,
  parseArgs,
} = require('./build-plugin.js');

// The SDK sources the host needs: base, common, the hosting classes.
const hostSdkSources = [
  'base/source/baseiids.cpp',
  'base/source/fbuffer.cpp',
  'base/source/fdebug.cpp',
  'base/source/fdynlib.cpp',
  'base/source/fobject.cpp',
  'base/source/fstreamer.cpp',
  'base/source/fstring.cpp',
  'base/source/timer.cpp',
  'base/source/updatehandler.cpp',
  'base/thread/source/fcondition.cpp',
  'base/thread/source/flock.cpp',
  'pluginterfaces/base/conststringtable.cpp',
  'pluginterfaces/base/coreiids.cpp',
  'pluginterfaces/base/funknown.cpp',
  'pluginterfaces/base/ustring.cpp',
  'public.sdk/source/common/commoniids.cpp',
  'public.sdk/source/common/commonstringconvert.cpp',
  'public.sdk/source/common/memorystream.cpp',
  'public.sdk/source/common/threadchecker_mac.mm',
  'public.sdk/source/vst/hosting/eventlist.cpp',
  'public.sdk/source/vst/hosting/hostclasses.cpp',
  'public.sdk/source/vst/hosting/module.cpp',
  'public.sdk/source/vst/hosting/module_mac.mm',
  'public.sdk/source/vst/hosting/parameterchanges.cpp',
  'public.sdk/source/vst/hosting/pluginterfacesupport.cpp',
  'public.sdk/source/vst/hosting/processdata.cpp',
  'public.sdk/source/vst/utility/stringconvert.cpp',
  'public.sdk/source/vst/vstinitiids.cpp',
];

async function buildHost() {
  const flags = [
    ...targetFlags,
    '-O2',
    '-DRELEASE=1',
    '-DSMTG_USE_STDATOMIC_H=1',
    '-I',
    sdkDir,
  ];
  const files = [
    ...hostSdkSources.map((file) => path.join(sdkDir, file)),
    path.join(root, 'test', 'host', 'aud_vst3_host.mm'),
  ];
  const objDir = path.join(buildDir, 'host');
  const objects = await compileAll('clang++', flags, files, objDir, headersHash([sdkDir]));
  const binary = path.join(objDir, `aud_vst3_host-${hashOf(objects)}`);
  if (!fs.existsSync(binary)) {
    run('clang++', [
      ...targetFlags,
      '-o',
      binary,
      ...objects,
      '-framework',
      'Cocoa',
      '-framework',
      'IOSurface',
      '-framework',
      'QuartzCore',
      '-framework',
      'ImageIO',
    ]);
  }
  return binary;
}

async function main() {
  let args = process.argv.slice(2);
  if (args.length === 0 || args[0].startsWith('--')) {
    const bundle = await build(parseArgs([]));
    args = [bundle, ...args];
  }
  if (!fs.existsSync(path.join(sdkDir, 'public.sdk', 'source', 'common', 'memorystream.cpp'))) {
    throw new Error('The vendored SDK lacks memorystream.cpp');
  }
  const binary = await buildHost();
  const result = spawnSync(binary, args, { stdio: 'inherit' });
  process.exit(result.status ?? 1);
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
