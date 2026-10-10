// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Runs a scenario of the spike (ticket 24) in REAPER: scripts/reaper/spike.lua
// does the work inside REAPER; this script prepares REAPER, samples the
// memory and CPU of REAPER and of its children (the editor processes) once
// a second, suspends or kills the editor for the crash scenario and prints
// the results with the probes' summary.
//
// REAPER starts through LaunchServices (`open -n`), as from the Dock: in
// front, so that its windows are not occluded - an occluded window stops
// the editors' frames.
//
// REAPER runs with a resource folder of its own under .dart_tool/reaper: a
// copy of the user's reaper.ini set to CoreAudio at 48 kHz and 128 frames,
// so that the user's own settings stay as they are. The plugins must be
// installed (build-plugin.js --install).
//
// Keyboard and mouse input reaches REAPER, which is in front: with --idle
// the run waits until the Mac had no input for that many seconds and the
// screen is not locked, and keeps the display awake. A run that sees
// input, a sleeping display or a locked screen is marked `disturbed`.
//
// REAPER's script clock is the wall clock; the measurements pair it with
// the probe's clock (mach time), so that the summary leaves out REAPER's
// start and quit. CPU counts from --cpu-from to --cpu-to seconds after the
// script started (3 s to the end of the scenario by default). The samples
// stay in .dart_tool/reaper/result-<stamp>.json.
//
//   node scripts/reaper.js --plugin "Aud Spike A1" --scenario open \
//     [--instances 2] [--duration 10] [--cycles 100] [--plugin ...] \
//     [--cpu-from s] [--cpu-to s] [--idle s]

'use strict';

const { spawn, spawnSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const root = path.resolve(__dirname, '..');
const reaper = '/Applications/REAPER.app/Contents/MacOS/REAPER';
const userResources = path.join(os.homedir(), 'Library', 'Application Support', 'REAPER');
const work = path.join(root, '.dart_tool', 'reaper');
const logDir = path.join(os.homedir(), 'Library', 'Logs', 'aud_audio_vst3');

function parseArgs(argv) {
  const options = {
    plugins: [],
    scenario: 'open',
    instances: 1,
    duration: 10,
    cycles: 100,
    cpuFrom: 3,
    cpuTo: null,
    idle: 0,
  };
  for (let i = 0; i < argv.length; ++i) {
    const arg = argv[i];
    if (arg === '--plugin') options.plugins.push(argv[++i]);
    else if (arg === '--scenario') options.scenario = argv[++i];
    else if (arg === '--instances') options.instances = Number(argv[++i]);
    else if (arg === '--duration') options.duration = Number(argv[++i]);
    else if (arg === '--cycles') options.cycles = Number(argv[++i]);
    else if (arg === '--cpu-from') options.cpuFrom = Number(argv[++i]);
    else if (arg === '--cpu-to') options.cpuTo = Number(argv[++i]);
    else if (arg === '--idle') options.idle = Number(argv[++i]);
    else throw new Error(`Unknown option ${arg}`);
  }
  if (options.plugins.length === 0) throw new Error('Name at least one --plugin');
  return options;
}

// reaper.ini of the user with CoreAudio at 48 kHz and 128 frames.
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
    // Plugins process while the transport stops.
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

// The test host measures the footprint and the CPU time of REAPER and of
// its children (spike-host.js builds it).
function measureTool() {
  const result = spawnSync(process.execPath, [path.join(__dirname, 'spike-host.js'), '--path'], {
    encoding: 'utf8',
  });
  if (result.status !== 0) throw new Error(`spike-host.js failed:\n${result.stderr}`);
  return result.stdout.trim();
}

function measure(tool, pid) {
  const result = spawnSync(tool, ['--measure', String(pid)], { encoding: 'utf8' });
  try {
    return JSON.parse(result.stdout);
  } catch {
    return null;
  }
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// Seconds since the last keyboard or mouse input.
function idleSeconds() {
  const result = spawnSync('ioreg', ['-c', 'IOHIDSystem', '-r', '-d', '1', '-k', 'HIDIdleTime'], {
    encoding: 'utf8',
  });
  const match = /"HIDIdleTime" = (\d+)/.exec(result.stdout ?? '');
  return match ? Number(match[1]) / 1e9 : 0;
}

function session(tool) {
  const result = spawnSync(tool, ['--session'], { encoding: 'utf8' });
  try {
    return JSON.parse(result.stdout);
  } catch {
    return { displayAsleep: false, screenLocked: false };
  }
}

// Waits until the Mac had no input for `seconds` and the screen is not
// locked; wakes the display.
async function waitForIdleMac(tool, seconds) {
  let told = false;
  for (;;) {
    const state = session(tool);
    if (idleSeconds() >= seconds && !state.screenLocked) {
      if (state.displayAsleep) {
        spawnSync('caffeinate', ['-u', '-t', '2']);
        await sleep(3000);
      }
      return;
    }
    if (!told) {
      console.error(`Waiting until the Mac had no input for ${seconds} s`);
      told = true;
    }
    await sleep(5000);
  }
}

// The process in front: its pid and name.
function frontApp() {
  const front = spawnSync('lsappinfo', ['front'], { encoding: 'utf8' }).stdout.trim();
  const info = spawnSync('lsappinfo', ['info', '-only', 'pid', '-only', 'name', front], {
    encoding: 'utf8',
  }).stdout;
  const pid = /"?pid"?\s*=\s*(\d+)/.exec(info);
  const name = /"LSDisplayName"="([^"]*)"/.exec(info) ?? /^\s*"([^"]+)"/.exec(info);
  return { pid: pid ? Number(pid[1]) : null, name: name ? name[1] : null };
}

// The pid of the REAPER that opens `project`.
async function reaperPid(project, gone) {
  for (let attempt = 0; attempt < 300 && !gone(); ++attempt) {
    const result = spawnSync('pgrep', ['-f', project], { encoding: 'utf8' });
    const pids = result.stdout.split('\n').filter(Boolean).map(Number);
    const own = pids.filter((pid) => {
      const command = spawnSync('ps', ['-o', 'command=', '-p', String(pid)], { encoding: 'utf8' });
      return command.stdout.startsWith(reaper);
    });
    if (own.length > 0) return own[0];
    await sleep(100);
  }
  return null;
}

// The editor processes REAPER started (the editor app of the plugins).
function editors(pid) {
  const result = spawnSync('pgrep', ['-l', '-P', String(pid)], { encoding: 'utf8' });
  return result.stdout
    .split('\n')
    .filter((line) => /\saud_audio/.test(line))
    .map((line) => Number(line.split(' ')[0]));
}

function readEvents(runLog) {
  if (!fs.existsSync(runLog)) return [];
  return fs
    .readFileSync(runLog, 'utf8')
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

// The crash scenario, in seconds after the script started (spike.lua opens
// and reopens the editors): kill the first editor process, then suspend
// the one that replaced it for ten seconds.
function crashStep(seconds, state, pid, runLog) {
  const note = (kind, victim) =>
    fs.appendFileSync(runLog, `{"kind":"${kind}","pid":${victim},"at":${seconds.toFixed(2)}}\n`);
  if (seconds >= 4 && !state.killed) {
    state.killed = true;
    const victim = editors(pid)[0];
    if (victim === undefined) return note('noEditor', 0);
    process.kill(victim, 'SIGKILL');
    note('kill', victim);
  }
  if (seconds >= 10 && !state.stopped) {
    state.stopped = editors(pid)[0];
    if (state.stopped === undefined) return note('noEditor', 0);
    process.kill(state.stopped, 'SIGSTOP');
    note('stop', state.stopped);
  }
  if (seconds >= 20 && state.stopped && !state.continued) {
    state.continued = true;
    process.kill(state.stopped, 'SIGCONT');
    note('cont', state.stopped);
  }
}

async function main() {
  const options = parseArgs(process.argv.slice(2));
  const tool = measureTool();
  if (options.idle > 0) await waitForIdleMac(tool, options.idle);
  // Keeps the display awake while this script runs.
  const awake = spawn('caffeinate', ['-d', '-i', '-w', String(process.pid)], { stdio: 'ignore' });
  const ini = prepareResources();
  const stamp = Date.now();
  const runLog = path.join(work, `run-${stamp}.jsonl`);
  const configFile = path.join(work, `config-${stamp}.lua`);
  fs.writeFileSync(
    configFile,
    `return { plugins = { ${options.plugins.map((p) => JSON.stringify(p)).join(', ')} }, ` +
      `scenario = ${JSON.stringify(options.scenario)}, instances = ${options.instances}, ` +
      `duration = ${options.duration}, cycles = ${options.cycles}, ` +
      `log = ${JSON.stringify(runLog)} }\n`,
  );
  const project = path.join(work, `spike-${stamp}.rpp`);
  const launcher = spawn(
    'open',
    ['-n', '-W', '-a', path.dirname(path.dirname(path.dirname(reaper))),
      '--env', `AUD_REAPER_CONFIG=${configFile}`, '--args',
      '-cfgfile', ini, '-nosplash', '-newinst', '-new', '-saveas', project,
      path.join(root, 'scripts', 'reaper', 'spike.lua')],
    { stdio: 'ignore' },
  );
  let exited = false;
  launcher.on('exit', () => {
    exited = true;
  });
  const child = { pid: await reaperPid(project, () => exited) };
  if (child.pid === null) throw new Error('REAPER did not start');
  const idleAtLaunch = idleSeconds();
  const launched = Date.now();
  let disturbed = null;
  // Ten ticks a second: the crash scenario acts within 100 ms of its
  // times; the memory is sampled once a second.
  const samples = [];
  const started = Date.now();
  const limit = (options.duration + options.cycles * 0.7 + 180) * 1000;
  let scriptStart = null;
  const crash = {};
  for (let tick = 0; !exited && Date.now() - started < limit; ++tick) {
    await new Promise((resolve) => setTimeout(resolve, 100));
    if (exited) break;
    if (scriptStart === null && readEvents(runLog).some((e) => e.kind === 'start')) {
      scriptStart = Date.now();
    }
    const seconds = scriptStart === null ? null : (Date.now() - scriptStart) / 1000;
    if (options.scenario === 'crash' && seconds !== null) {
      crashStep(seconds, crash, child.pid, runLog);
    }
    if (tick % 10 === 0) {
      const before = Date.now();
      const sample = measure(tool, child.pid);
      const wallMs = (before + Date.now()) / 2;
      if (sample) samples.push({ ...sample, seconds, wallMs, front: frontApp() });
      const sinceLaunch = (Date.now() - launched) / 1000;
      const state = session(tool);
      if (disturbed === null && idleSeconds() + 2 < idleAtLaunch + sinceLaunch) {
        disturbed = { reason: 'input', seconds };
      }
      if (disturbed === null && (state.displayAsleep || state.screenLocked)) {
        disturbed = { reason: state.screenLocked ? 'screenLocked' : 'displayAsleep', seconds };
      }
    }
  }
  if (!exited) {
    process.kill(child.pid, 'SIGTERM');
    console.log('REAPER did not quit in time; terminated.');
  }
  awake.kill();
  const probe = path.join(logDir, `probe-${child.pid}.jsonl`);
  const events = readEvents(runLog);
  // The probe's clock minus the wall clock, in ns.
  const offsets = samples.map((s) => s.t - s.wallMs * 1e6).sort((a, b) => a - b);
  const offset = offsets[Math.floor(offsets.length / 2)];
  const machOf = (kind) => {
    const event = events.find((e) => e.kind === kind);
    return event && offset !== undefined ? Math.round(event.t * 1e9 + offset) : null;
  };
  // The samples between the script's start and its end, before REAPER
  // quits.
  const startEvent = events.find((e) => e.kind === 'start');
  const doneEvent = events.find((e) => e.kind === 'done');
  const doneSeconds = startEvent && doneEvent ? doneEvent.t - startEvent.t : Infinity;
  const timed = samples.filter((s) => s.seconds !== null && s.seconds <= doneSeconds);
  const result = {
    pid: child.pid,
    scenario: options.scenario,
    plugins: options.plugins,
    instances: options.instances,
    disturbed,
    events: events.filter((e) => !['show', 'hide', 'tick'].includes(e.kind)),
    // Seconds in which REAPER's audio did not run or the transport stopped,
    // and samples in which another app than REAPER was in front.
    audioStopped: events.filter((e) => e.kind === 'tick' && (e.audio === 0 || e.play === 0)).length,
    frontLost: timed.filter((s) => s.front?.pid !== child.pid).length,
    memory: summarizeMemory(timed),
    cpu: summarizeCpu(timed, options.cpuFrom, options.cpuTo),
    probe: fs.existsSync(probe) ? probe : null,
  };
  fs.writeFileSync(path.join(work, `result-${stamp}.json`), JSON.stringify({ ...result, samples }));
  console.log(JSON.stringify(result));
  if (fs.existsSync(probe)) {
    const window = ['start', 'done'].map(machOf);
    const args = [path.join(__dirname, 'analyze-probe.js'), probe];
    if (window[0] !== null && window[1] !== null) {
      args.push('--from', String(window[0]), '--to', String(window[1]));
    }
    const analysis = spawnSync(process.execPath, args, { encoding: 'utf8' });
    process.stdout.write(analysis.stdout + analysis.stderr);
  }
}

const mb = (bytes) => Math.round(bytes / 1e5) / 10;

function spread(values) {
  if (values.length === 0) return null;
  const sorted = [...values].sort((a, b) => a - b);
  return {
    first: values[0],
    median: sorted[Math.floor(sorted.length / 2)],
    max: sorted.at(-1),
    last: values.at(-1),
  };
}

// REAPER's footprint and the editor processes' footprints, in MB.
function summarizeMemory(samples) {
  return {
    samples: samples.length,
    reaperMb: spread(samples.map((s) => mb(s.bytes))),
    editorsMb: spread(samples.map((s) => mb(s.childList.reduce((sum, c) => sum + c.bytes, 0)))),
    editorProcesses: spread(samples.map((s) => s.childList.length)),
  };
}

// The CPU load of REAPER and of the editor processes, in percent of one
// core, between two samples of the window.
function summarizeCpu(samples, from, to) {
  const end = to ?? (samples.at(-1)?.seconds ?? 0) - 1;
  const inWindow = samples.filter((s) => s.seconds >= from && s.seconds <= end);
  if (inWindow.length < 2) return null;
  const first = inWindow[0];
  const last = inWindow.at(-1);
  const elapsedNs = (last.seconds - first.seconds) * 1e9;
  let editorsNs = 0;
  for (const child of last.childList) {
    const before = first.childList.find((c) => c.pid === child.pid);
    editorsNs += child.cpuNs - (before ? before.cpuNs : 0);
  }
  const percent = (ns) => Math.round((ns / elapsedNs) * 1000) / 10;
  return {
    fromS: Math.round(first.seconds * 10) / 10,
    toS: Math.round(last.seconds * 10) / 10,
    reaperPercent: percent(last.cpuNs - first.cpuNs),
    editorsPercent: percent(editorsNs),
  };
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
