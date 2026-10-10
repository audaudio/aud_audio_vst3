// @license
// Copyright (c) Audanika. All Rights Reserved.
//
// Use of this source code is governed by terms that can be
// found in the LICENSE file in the root of this package.

// Summarizes the probe log of a plugin process (ticket 24):
// ~/Library/Logs/aud_audio_vst3/probe-<pid>.jsonl, written by the plugin and
// the editor process. Joins the records of one parameter change by
// instance, id and value:
//
// - UI to audio: input event (`edit.input`) → first `process` call that
//   carries the value; split into input → edit (the editor's share) and
//   edit → process (the host's share); and → `rendered`, the first block
//   the engine renders after the control thread passed the change on.
// - Audio to UI: `hostParam` → `drawn` (native view) or `presented` (the
//   frame of the Flutter editor shown in the plugin's view).
// - Editor open: `attached` → `firstFrame`.
//
// - UI stalls: the worst delay of the host's UI thread per second, from
//   the plugin's watch; --from and --to (probe clock, ns) leave out what
//   lies outside, such as the start and the quit of the host.
//
//   node scripts/analyze-probe.js [<probe.jsonl>] [--from ns --to ns]
//   the newest log by default

'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const logDir = path.join(os.homedir(), 'Library', 'Logs', 'aud_audio_vst3');

function newestProbe() {
  const files = fs
    .readdirSync(logDir)
    .filter((file) => file.startsWith('probe-') && file.endsWith('.jsonl'))
    .map((file) => path.join(logDir, file))
    .sort((a, b) => fs.statSync(b).mtimeMs - fs.statSync(a).mtimeMs);
  if (files.length === 0) throw new Error(`No probe log in ${logDir}`);
  return files[0];
}

function percentile(sorted, p) {
  if (sorted.length === 0) return NaN;
  const index = Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1);
  return sorted[Math.max(0, index)];
}

function stats(values) {
  const sorted = [...values].sort((a, b) => a - b);
  const ms = (ns) => Math.round(ns / 1e4) / 100;
  if (sorted.length === 0) return { count: 0 };
  return {
    count: sorted.length,
    medianMs: ms(percentile(sorted, 50)),
    p90Ms: ms(percentile(sorted, 90)),
    p99Ms: ms(percentile(sorted, 99)),
    maxMs: ms(sorted[sorted.length - 1] ?? NaN),
  };
}

// Instance numbers count per plugin image: two builds in one host both
// have an instance 1, the build tells them apart.
function keyOf(record) {
  return `${record.build}/${record.instance}/${record.id}/${Number(record.value).toFixed(6)}`;
}

function instanceOf(record) {
  return `${record.build}/${record.instance}`;
}

function analyze(records, window) {
  const edits = records.filter((r) => r.kind === 'edit' && r.input > 0);
  const processes = records.filter((r) => r.kind === 'process');
  const applied = records.filter((r) => r.kind === 'applied');
  const rendered = records.filter((r) => r.kind === 'rendered');

  // The process records by key, in time order.
  const processByKey = new Map();
  for (const record of processes) {
    const key = keyOf(record);
    if (!processByKey.has(key)) processByKey.set(key, []);
    processByKey.get(key).push(record);
  }
  const total = [];
  const editorShare = [];
  const hostShare = [];
  const toRendered = [];
  let unmatched = 0;
  for (const edit of edits) {
    const candidates = processByKey.get(keyOf(edit)) ?? [];
    const process = candidates.find((record) => record.t >= edit.t);
    if (!process) {
      unmatched += 1;
      continue;
    }
    total.push(process.t - edit.input);
    editorShare.push(edit.t - edit.input);
    hostShare.push(process.t - edit.t);
    // The control thread passes changes on in order: the first applied
    // record after the process record, then the first rendered block whose
    // sequence covers it.
    const apply = applied.find(
      (record) => record.t >= process.t && record.id === process.id,
    );
    if (apply) {
      const block = rendered.find(
        (record) => record.t >= apply.t && record.value >= apply.sequence,
      );
      if (block) toRendered.push(block.t - edit.input);
    }
  }

  // Audio to UI. The native view logs `drawn` with the value it drew;
  // the Flutter editor gets `paramSent` with a sequence number, logs
  // `paramApplied` when its knob took the value, and the plugin logs
  // `presented` for every frame it shows - the first frame captured
  // after the knob took the value shows it.
  const hostParams = records.filter((r) => r.kind === 'hostParam');
  const drawn = records.filter((r) => r.kind === 'drawn');
  const sent = records.filter((r) => r.kind === 'paramSent');
  const appliedInEditor = new Map(
    records
      .filter((r) => r.kind === 'paramApplied')
      .map((r) => [`${instanceOf(r)}/${r.seq}`, r]),
  );
  const presented = records.filter((r) => r.kind === 'presented');
  const audioToUi = [];
  for (const param of hostParams) {
    if (sent.length === 0) {
      const match = drawn.find(
        (record) => record.t >= param.t && keyOf(record) === keyOf(param),
      );
      if (match) audioToUi.push(match.t - param.t);
      continue;
    }
    const out = sent.find(
      (record) => record.t >= param.t && keyOf(record) === keyOf(param),
    );
    if (!out) continue;
    const taken = appliedInEditor.get(`${instanceOf(out)}/${out.seq}`);
    if (!taken) continue;
    const frame = presented.find(
      (record) => instanceOf(record) === instanceOf(out) && record.captured >= taken.t,
    );
    if (frame) audioToUi.push(frame.t - param.t);
  }

  const opens = records
    .filter((r) => r.kind === 'firstFrame')
    .map((r) => r.ns);

  // The host's UI thread, as the plugin's watch saw it: the worst delay of
  // a block posted to the main queue, per second and plugin instance.
  // A record covers the second before its time.
  const stalls = records
    .filter((r) => r.kind === 'uiStall')
    .filter((r) => r.t - 1e9 >= window.from && r.t <= window.to)
    .map((r) => r.worstNs);

  return {
    uiToAudio: { total: stats(total), editor: stats(editorShare), host: stats(hostShare), rendered: stats(toRendered), unmatched },
    audioToUi: stats(audioToUi),
    editorOpen: stats(opens),
    uiStall: {
      ...stats(stalls),
      over50Ms: stalls.filter((ns) => ns > 50e6).length,
      over250Ms: stalls.filter((ns) => ns > 250e6).length,
    },
    removed: stats(records.filter((r) => r.kind === 'removed').map((r) => r.ns)),
    init: records.filter((r) => r.kind === 'init').slice(0, 4),
    attached: records.filter((r) => r.kind === 'attached').slice(0, 4),
    dropped: records.filter((r) => r.kind === 'dropped'),
    // Written when an engine closes: its blocks, overloads, slowest block
    // and, in a watchdog build, its realtime violations.
    engineStats: records
      .filter((r) => r.kind === 'engineStats')
      .map(({ build, instance, blocks, overloads, renderMaxNs, realtimeViolations, watchdog }) => ({
        build, instance, blocks, overloads, renderMaxNs, realtimeViolations, watchdog,
      })),
  };
}

function main() {
  const args = process.argv.slice(2);
  const window = { from: -Infinity, to: Infinity };
  let file = null;
  for (let i = 0; i < args.length; ++i) {
    if (args[i] === '--from') window.from = Number(args[++i]);
    else if (args[i] === '--to') window.to = Number(args[++i]);
    else file = args[i];
  }
  file ??= newestProbe();
  const records = fs
    .readFileSync(file, 'utf8')
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line));
  console.log(file);
  for (const [name, value] of Object.entries(analyze(records, window))) {
    console.log(`${name}: ${JSON.stringify(value)}`);
  }
}

main();
