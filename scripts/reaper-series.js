// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Runs the REAPER measurements of the spike (ticket 24) one after the
// other with scripts/reaper.js: each run waits until the Mac had no input
// for 90 s, and a run that saw input is repeated. Every run lands as one
// JSON line in .dart_tool/reaper/series-<stamp>.jsonl; a line per run goes
// to stdout.
//
//   node scripts/reaper-series.js [--only <regex>] [--list] [--idle s]

'use strict';

const { spawn } = require('node:child_process');
const fs = require('node:fs');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const work = path.join(root, '.dart_tool', 'reaper');

// The full names keep "Aud Spike C1" from matching "Aud Spike C1 (no
// hygiene)" or a watchdog build.
const plugin = (name) => `Aud Spike ${name} (Audanika)`;
const flutterVariants = ['A1', 'S1', 'F1', 'B1'];

function runs() {
  const list = [];
  const add = (name, plugins, scenario, extra = []) =>
    list.push({
      name,
      args: [...plugins.flatMap((p) => ['--plugin', plugin(p)]), '--scenario', scenario, ...extra],
    });
  for (const v of ['D1', 'C1', ...flutterVariants]) add(`closed ${v}`, [v], 'closed');
  for (const v of ['D1', 'C1', ...flutterVariants]) {
    add(`open ${v} x1`, [v], 'open', ['--duration', '30', '--cpu-from', '5', '--cpu-to', '27']);
  }
  // CPU of an editor with nothing to animate (the output silent).
  for (const v of ['D1', 'C1', ...flutterVariants]) {
    add(`idle ${v}`, [v], 'idle', ['--duration', '30', '--cpu-from', '6', '--cpu-to', '27']);
  }
  for (const n of [2, 4]) {
    for (const v of ['C1', 'A1', 'S1', 'B1']) {
      add(`open ${v} x${n}`, [v], 'open', ['--instances', String(n), '--duration', '20', '--cpu-from', '5', '--cpu-to', '17']);
    }
  }
  for (const v of ['C1', ...flutterVariants]) {
    add(`test ${v}`, [v], 'test', ['--cpu-from', '5', '--cpu-to', '20']);
  }
  for (const v of ['C1', ...flutterVariants]) {
    add(`automate ${v}`, [v], 'automate', ['--cpu-from', '4', '--cpu-to', '19']);
  }
  for (const v of ['C1', ...flutterVariants]) add(`cycles ${v}`, [v], 'cycles', ['--cycles', '100']);
  for (const v of ['A1', 'S1', 'F1']) add(`crash ${v}`, [v], 'crash');
  add('pair A1+A2', ['A1', 'A2'], 'pair');
  add('pair B1+B2', ['B1', 'B2'], 'pair');
  add('pair C1+C2', ['C1', 'C2'], 'pair');
  add('pair C1+C2 no hygiene', ['C1 (no hygiene)', 'C2 (no hygiene)'], 'pair');
  add('soak A1 watchdog x2', ['A1 (watchdog)'], 'soak', [
    '--instances', '2', '--duration', '600', '--cpu-from', '10', '--cpu-to', '590',
  ]);
  return list;
}

function parseArgs(argv) {
  const options = { only: null, list: false, idle: 90, attempts: 8 };
  for (let i = 0; i < argv.length; ++i) {
    if (argv[i] === '--only') options.only = new RegExp(argv[++i]);
    else if (argv[i] === '--list') options.list = true;
    else if (argv[i] === '--idle') options.idle = Number(argv[++i]);
    else throw new Error(`Unknown option ${argv[i]}`);
  }
  return options;
}

// Runs reaper.js; returns its result and the probe analysis.
function runOnce(args, idle) {
  return new Promise((resolve) => {
    const child = spawn(
      process.execPath,
      [path.join(__dirname, 'reaper.js'), ...args, '--idle', String(idle)],
      { stdio: ['ignore', 'pipe', 'inherit'] },
    );
    let out = '';
    child.stdout.on('data', (chunk) => {
      out += chunk;
    });
    child.on('close', (code) => {
      let result = null;
      const analysis = {};
      for (const line of out.split('\n')) {
        if (line.startsWith('{"pid"')) result = JSON.parse(line);
        const match = /^(\w+): (.*)$/.exec(line);
        if (match) analysis[match[1]] = JSON.parse(match[2]);
      }
      resolve({ code, result, analysis, timedOut: out.includes('did not quit in time') });
    });
  });
}

function oneLine(name, run) {
  const { result, analysis } = run;
  if (!result) return `${name}: no result`;
  const parts = [name];
  const memory = result.memory;
  if (memory?.reaperMb) parts.push(`reaper ${memory.reaperMb.median} MB (max ${memory.reaperMb.max})`);
  if (memory?.editorsMb?.max) parts.push(`editors ${memory.editorsMb.median} MB (max ${memory.editorsMb.max})`);
  if (result.cpu) parts.push(`cpu ${result.cpu.reaperPercent}% + ${result.cpu.editorsPercent}%`);
  const ms = (s) => (s?.count ? `${s.medianMs}/${s.p99Ms ?? s.maxMs} ms` : null);
  if (ms(analysis.uiToAudio?.total)) parts.push(`ui→audio ${ms(analysis.uiToAudio.total)}`);
  if (ms(analysis.audioToUi)) parts.push(`audio→ui ${ms(analysis.audioToUi)}`);
  if (ms(analysis.editorOpen)) parts.push(`open ${ms(analysis.editorOpen)} (${analysis.editorOpen.count})`);
  if (analysis.uiStall?.count) parts.push(`stall max ${analysis.uiStall.maxMs} ms`);
  const blocks = (analysis.engineStats ?? []).map((s) => s.blocks);
  if (blocks.length > 0) parts.push(`blocks ${blocks.join('/')}`);
  if (result.audioStopped) parts.push(`audio stopped ${result.audioStopped} s`);
  if (result.frontLost) parts.push(`not in front ${result.frontLost} s`);
  if (result.disturbed) parts.push(`DISTURBED (${result.disturbed.reason})`);
  if (run.timedOut) parts.push('TIMED OUT');
  return parts.join(', ');
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const selected = runs().filter((run) => !options.only || options.only.test(run.name));
  if (options.list) {
    for (const run of selected) console.log(run.name);
    return;
  }
  fs.mkdirSync(work, { recursive: true });
  const file = path.join(work, `series-${Date.now()}.jsonl`);
  console.log(`Writing ${path.relative(root, file)}`);
  for (const run of selected) {
    for (let attempt = 1; attempt <= options.attempts; ++attempt) {
      const outcome = await runOnce(run.args, options.idle);
      fs.appendFileSync(file, `${JSON.stringify({ name: run.name, attempt, ...outcome })}\n`);
      console.log(`${oneLine(run.name, outcome)}${attempt > 1 ? ` [attempt ${attempt}]` : ''}`);
      if (!outcome.result?.disturbed) break;
    }
  }
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
