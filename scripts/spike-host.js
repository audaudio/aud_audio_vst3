// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Builds the test host of the spike (test/host/aud_spike_host.mm) against
// the SDK's hosting classes of the vendored subset and runs it with the
// remaining arguments (ticket 24). With --rtsan the host is built with
// LLVM's RealtimeSanitizer, so that its runtime is loaded at process start
// and catches what a plugin built with `build-plugin.js --rtsan` does on
// the audio thread.
//
//   node scripts/spike-host.js [--rtsan] --plugin build/vst3/AudSpikeC1.vst3 \
//     --scenario test
//   node scripts/spike-host.js --path    builds the host, prints its path

'use strict';

const { createHash } = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const sdkDir = path.join(root, 'src', 'third_party', 'vst3sdk');

// The hosting sources of the validator, without its test suite.
function hostingSources() {
  return fs
    .readFileSync(path.join(sdkDir, 'VALIDATOR_SOURCES.txt'), 'utf8')
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean)
    .filter(
      (file) =>
        !file.includes('/testsuite/') &&
        !file.includes('/hosting/test/') &&
        !file.includes('/samples/vst-hosting/validator/') &&
        // The module init of a plugin; a host has no module handle.
        !file.endsWith('/main/moduleinit.cpp'),
    )
    .map((file) => path.join(sdkDir, file));
}

function hashOf(parts) {
  const hash = createHash('sha256');
  for (const part of parts) hash.update(part).update('\0');
  return hash.digest('hex').slice(0, 20);
}

function rtsanCompiler() {
  for (const candidate of [
    process.env.AUD_RTSAN_CXX,
    '/opt/homebrew/opt/llvm/bin/clang++',
    '/usr/local/opt/llvm/bin/clang++',
  ].filter(Boolean)) {
    if (fs.existsSync(candidate)) return candidate;
  }
  throw new Error('RealtimeSanitizer needs LLVM from Homebrew');
}

async function build(rtsan) {
  const compiler = rtsan ? rtsanCompiler() : 'clang++';
  const buildDir = path.join(
    root,
    '.dart_tool',
    'vst3-build',
    rtsan ? 'host-rtsan' : 'host',
  );
  fs.mkdirSync(buildDir, { recursive: true });
  const flags = [
    '-arch',
    'arm64',
    '-mmacosx-version-min=12.0',
    '-O1',
    '-g',
    '-DRELEASE=1',
    '-DSMTG_USE_STDATOMIC_H=1',
    '-I',
    sdkDir,
    ...(rtsan ? ['-fsanitize=realtime'] : []),
  ];
  const files = [...hostingSources(), path.join(root, 'test', 'host', 'aud_spike_host.mm')];
  const jobs = files.map((file) => {
    const objc = file.endsWith('.mm');
    const args = [
      ...flags,
      ...(objc ? ['-x', 'objective-c++', '-fobjc-arc'] : ['-x', 'c++']),
      '-std=c++17',
    ];
    const key = hashOf([compiler, ...args, file, fs.readFileSync(file, 'utf8')]);
    return { file, args, object: path.join(buildDir, `${path.basename(file)}-${key}.o`) };
  });
  const pending = jobs.filter((job) => !fs.existsSync(job.object));
  let next = 0;
  const failures = [];
  async function worker() {
    while (next < pending.length) {
      const job = pending[next++];
      const code = await new Promise((resolve) => {
        const child = spawn(
          compiler,
          [...job.args, '-c', job.file, '-o', `${job.object}.tmp`],
          { stdio: 'inherit' },
        );
        child.on('close', resolve);
      });
      if (code === 0) fs.renameSync(`${job.object}.tmp`, job.object);
      else failures.push(job.file);
    }
  }
  await Promise.all(Array.from({ length: Math.max(1, os.cpus().length) }, worker));
  if (failures.length > 0) throw new Error(`Compilation failed: ${failures.join(', ')}`);
  const objects = jobs.map((job) => job.object);
  const binary = path.join(buildDir, `aud_spike_host-${hashOf(objects)}`);
  if (!fs.existsSync(binary)) {
    const result = spawnSync(
      compiler,
      [
        '-arch',
        'arm64',
        '-o',
        binary,
        ...objects,
        ...(rtsan ? ['-fsanitize=realtime'] : []),
        '-framework',
        'Cocoa',
        '-framework',
        'AudioToolbox',
        '-framework',
        'CoreAudio',
      ],
      { encoding: 'utf8' },
    );
    if (result.status !== 0) throw new Error(`Linking failed:\n${result.stderr}`);
  }
  return binary;
}

async function main() {
  const args = process.argv.slice(2);
  const rtsan = args.includes('--rtsan');
  const hostArgs = args.filter((arg) => arg !== '--rtsan');
  const binary = await build(rtsan);
  if (args.includes('--path')) {
    console.log(binary);
    return;
  }
  const child = spawn(binary, hostArgs, { stdio: 'inherit' });
  child.on('close', (code) => process.exit(code ?? 1));
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
