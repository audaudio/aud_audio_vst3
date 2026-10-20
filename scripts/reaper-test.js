// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Tests a plugin in REAPER (ticket 37): scripts/reaper/test.lua adds it to a
// track, renders a MIDI item with a note on each of the MIDI channels 1 to 4
// offline with several presets, plays it live and opens the saved project
// again. This script prepares REAPER, waits for it to quit, and checks the
// log and the rendered files: REAPER found the plugin, every rendered preset
// sounds above -60 dBFS and stays at or below 0 dBFS, the live play sounds,
// and the reopened project holds the preset it was saved with.
//
// REAPER runs with a resource folder of its own under .dart_tool/reaper: a
// copy of the user's reaper.ini set to CoreAudio at 48 kHz and 128 frames,
// so that the user's own settings stay as they are. It finds the plugin in
// the user's plug-in folders, e.g. through the link of an app. REAPER comes
// to the front while it runs.
//
//   node scripts/reaper-test.js [--plugin "Audanika"] [--render 0,13,27]
//     [--presets 28]

'use strict';

const { spawn } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const reaperApp = '/Applications/REAPER.app';
const userResources = path.join(os.homedir(), 'Library', 'Application Support', 'REAPER');
const work = path.join(root, '.dart_tool', 'reaper');

// A rendered preset sounds above this and never exceeds full scale.
const audiblePeak = 0.001;

function parseArgs(argv) {
  const options = { plugin: 'Audanika', render: [0], presets: 1 };
  for (let i = 0; i < argv.length; ++i) {
    const arg = argv[i];
    if (arg === '--plugin') options.plugin = argv[++i];
    else if (arg === '--render') options.render = argv[++i].split(',').map(Number);
    else if (arg === '--presets') options.presets = Number(argv[++i]);
    else throw new Error(`Unknown option ${arg}`);
  }
  if (options.render.some((index) => !Number.isInteger(index) || index < 0 || index >= options.presets)) {
    throw new Error('--render names presets from 0 to --presets - 1');
  }
  return options;
}

function prepareResources() {
  fs.mkdirSync(work, { recursive: true });
  let ini = fs.existsSync(path.join(userResources, 'reaper.ini'))
    ? fs.readFileSync(path.join(userResources, 'reaper.ini'), 'utf8')
    : '[reaper]\n';
  const settings = {
    coreaudiobs: '128',
    coreaudiobsuse: '1',
    coreaudiosrate: '48000',
    coreaudiosrateuse: '1',
    splashfast: '1',
    runallonstop: '1',
  };
  for (const [key, value] of Object.entries(settings)) {
    const pattern = new RegExp(`^${key}=.*$`, 'm');
    ini = pattern.test(ini)
      ? ini.replace(pattern, `${key}=${value}`)
      : ini.replace('[reaper]\n', `[reaper]\n${key}=${value}\n`);
  }
  const file = path.join(work, 'reaper.ini');
  fs.writeFileSync(file, ini);
  return file;
}

// The peak of a WAV file: PCM of 16, 24 or 32 bits, or 32-bit float.
function wavPeak(file) {
  const bytes = fs.readFileSync(file);
  let offset = 12;
  let format = null;
  while (offset + 8 <= bytes.length) {
    const id = bytes.toString('ascii', offset, offset + 4);
    const size = bytes.readUInt32LE(offset + 4);
    const body = offset + 8;
    if (id === 'fmt ') {
      format = {
        tag: bytes.readUInt16LE(body),
        bits: bytes.readUInt16LE(body + 14),
      };
      if (format.tag === 0xfffe) format.tag = bytes.readUInt16LE(body + 24);
    } else if (id === 'data' && format) {
      let peak = 0;
      const step = format.bits / 8;
      for (let i = body; i + step <= body + size && i + step <= bytes.length; i += step) {
        let value;
        if (format.tag === 3) value = bytes.readFloatLE(i);
        else if (format.bits === 16) value = bytes.readInt16LE(i) / 32768;
        else if (format.bits === 24) value = bytes.readIntLE(i, 3) / 8388608;
        else value = bytes.readInt32LE(i) / 2147483648;
        peak = Math.max(peak, Math.abs(value));
      }
      return peak;
    }
    offset = body + size + (size % 2);
  }
  throw new Error(`${file} is no WAV file this script reads`);
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const ini = prepareResources();
  const stamp = new Date().toISOString().replace(/[:.]/g, '-');
  const runDir = path.join(work, `test-${stamp}`);
  const renderDir = path.join(runDir, 'render');
  fs.mkdirSync(renderDir, { recursive: true });
  const log = path.join(runDir, 'log.jsonl');
  const project = path.join(runDir, 'test.rpp');
  const configFile = path.join(runDir, 'config.lua');
  fs.writeFileSync(
    configFile,
    `return { plugin = ${JSON.stringify(options.plugin)}, presets = ${options.presets}, ` +
      `render = { ${options.render.join(', ')} }, renderDir = ${JSON.stringify(renderDir)}, ` +
      `project = ${JSON.stringify(project)}, log = ${JSON.stringify(log)} }\n`,
  );
  const reaper = spawn(
    'open',
    ['-n', '-W', '-a', reaperApp, '--env', `AUD_REAPER_CONFIG=${configFile}`, '--args',
      '-cfgfile', ini, '-nosplash', '-newinst', '-new', '-saveas', project,
      path.join(root, 'scripts', 'reaper', 'test.lua')],
    { stdio: 'ignore' },
  );
  const exited = new Promise((resolve) => reaper.on('exit', resolve));
  const timeout = new Promise((resolve) => setTimeout(() => resolve('timeout'), 300_000));
  if ((await Promise.race([exited, timeout])) === 'timeout') {
    throw new Error('REAPER did not finish within 5 minutes');
  }

  const events = fs.existsSync(log)
    ? fs.readFileSync(log, 'utf8').split('\n').filter(Boolean).map((line) => JSON.parse(line))
    : [];
  const checks = [];
  const check = (name, ok, detail) => {
    checks.push({ name, ok, ...detail });
    console.log(JSON.stringify({ check: name, ok, ...detail }));
  };
  const added = events.find((e) => e.kind === 'added');
  check('found', Boolean(added), { name: added?.name, error: events.find((e) => e.kind === 'error')?.message });
  for (const rendered of events.filter((e) => e.kind === 'rendered')) {
    const peak = fs.existsSync(rendered.file) ? wavPeak(rendered.file) : 0;
    check('render', peak > audiblePeak && peak <= 1, {
      preset: rendered.preset,
      name: rendered.name,
      peak: Number(peak.toFixed(4)),
      seconds: rendered.seconds,
    });
  }
  const played = events.find((e) => e.kind === 'played');
  check('live', Boolean(played) && played.peak > audiblePeak, { peak: played?.peak, audio: played?.audio });
  const saved = events.find((e) => e.kind === 'saved');
  const reopened = events.find((e) => e.kind === 'reopened');
  check('state', Boolean(saved && reopened) && Math.abs(saved.preset - reopened.preset) < 1e-3, {
    saved: saved?.preset,
    reopened: reopened?.preset,
  });
  check('done', events.some((e) => e.kind === 'done'), { log });
  process.exit(checks.every((c) => c.ok) ? 0 : 1);
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
