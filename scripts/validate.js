// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Builds the VST3 SDK's validator from the vendored subset
// (src/third_party/vst3sdk/VALIDATOR_SOURCES.txt) and runs it on bundles
// (ticket 24). Objects and the binary are cached under
// .dart_tool/vst3-build/validator.
//
//   node scripts/validate.js                     every bundle in build/vst3
//                                                but the RealtimeSanitizer ones
//   node scripts/validate.js <bundle.vst3> ...   the given bundles
//   node scripts/validate.js --extensive         the validator's -e mode

'use strict';

const { createHash } = require('node:crypto');
const { spawn, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const sdkDir = path.join(root, 'src', 'third_party', 'vst3sdk');
const buildDir = path.join(root, '.dart_tool', 'vst3-build', 'validator');

function hashOf(parts) {
  const hash = createHash('sha256');
  for (const part of parts) hash.update(part).update('\0');
  return hash.digest('hex').slice(0, 20);
}

function readList(file) {
  return fs
    .readFileSync(file, 'utf8')
    .split('\n')
    .map((line) => line.trim())
    .filter(Boolean);
}

async function compile(files, flags) {
  fs.mkdirSync(buildDir, { recursive: true });
  const jobs = files.map((file) => {
    const objc = file.endsWith('.mm');
    const args = [
      ...flags,
      ...(objc ? ['-x', 'objective-c++', '-fobjc-arc'] : ['-x', 'c++']),
      '-std=c++17',
    ];
    const key = hashOf([...args, file, fs.readFileSync(file, 'utf8')]);
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
          'clang++',
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
  return jobs.map((job) => job.object);
}

async function buildValidator() {
  const files = readList(path.join(sdkDir, 'VALIDATOR_SOURCES.txt')).map((file) =>
    path.join(sdkDir, file),
  );
  const flags = [
    '-arch',
    'arm64',
    '-mmacosx-version-min=12.0',
    '-O1',
    '-DRELEASE=1',
    '-DSMTG_USE_STDATOMIC_H=1',
    '-I',
    sdkDir,
  ];
  const objects = await compile(files, flags);
  const binary = path.join(buildDir, `validator-${hashOf(objects)}`);
  if (!fs.existsSync(binary)) {
    const result = spawnSync(
      'clang++',
      ['-arch', 'arm64', '-o', binary, ...objects, '-framework', 'Cocoa'],
      { encoding: 'utf8' },
    );
    if (result.status !== 0) throw new Error(`Linking failed:\n${result.stderr}`);
  }
  return binary;
}

async function main() {
  const args = process.argv.slice(2);
  const extensive = args.includes('--extensive');
  let bundles = args.filter((arg) => !arg.startsWith('--'));
  if (bundles.length === 0) {
    const out = path.join(root, 'build', 'vst3');
    bundles = fs
      .readdirSync(out)
      .filter((entry) => entry.endsWith('.vst3'))
      // RealtimeSanitizer builds need its runtime at process start, which
      // the validator does not load; spike-host.js --rtsan runs them.
      .filter((entry) => !entry.includes('Rtsan'))
      .map((entry) => path.join(out, entry));
  }
  const validator = await buildValidator();
  let failed = 0;
  for (const bundle of bundles) {
    const result = spawnSync(
      validator,
      [...(extensive ? ['-e'] : []), bundle],
      { encoding: 'utf8' },
    );
    const output = `${result.stdout}${result.stderr}`;
    const summary = output
      .split('\n')
      .filter((line) => /Result:|tests passed|tests failed/.test(line))
      .join('\n');
    console.log(`${path.basename(bundle)}: ${result.status === 0 ? 'passed' : 'FAILED'}`);
    if (summary) console.log(summary);
    if (result.status !== 0) {
      failed += 1;
      console.log(output.split('\n').filter((line) => /ERROR|Failed|failed/.test(line)).join('\n'));
    }
  }
  process.exit(failed === 0 ? 0 : 1);
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
