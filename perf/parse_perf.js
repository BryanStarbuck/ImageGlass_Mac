#!/usr/bin/env node
// Streams a performance.log file (key=value lines), aggregates by `action`
// over the `phase=finish` records (which carry `elapsed_ms`), and writes a
// CSV with: action, instance_count, avg_elapsed_ms, total_elapsed_ms,
// min_elapsed_ms, max_elapsed_ms.
//
// Usage: node parse_perf.js <input.log> [output.csv]

'use strict';

const fs = require('fs');
const readline = require('readline');
const path = require('path');

const input = process.argv[2];
const output = process.argv[3] || path.join(path.dirname(input || '.'), 'perf_report.csv');

if (!input) {
  console.error('usage: node parse_perf.js <input.log> [output.csv]');
  process.exit(1);
}

const stats = new Map(); // action -> { count, total, min, max }
let totalLines = 0;
let finishLines = 0;
let startedAt = Date.now();

function parseLine(line) {
  // Lines look like:
  // ts=... phase=finish action=Foo.Bar instance=3 corr=abc elapsed_ms=12
  // We only need phase, action, elapsed_ms.
  let phase = null;
  let action = null;
  let elapsed = null;
  // Cheap manual parse - faster than split for huge files.
  let i = 0;
  const n = line.length;
  while (i < n) {
    // skip whitespace
    while (i < n && line.charCodeAt(i) === 32) i++;
    // find '='
    const keyStart = i;
    while (i < n && line.charCodeAt(i) !== 61 /* = */ && line.charCodeAt(i) !== 32) i++;
    if (i >= n || line.charCodeAt(i) !== 61) break;
    const key = line.slice(keyStart, i);
    i++; // skip '='
    const valStart = i;
    while (i < n && line.charCodeAt(i) !== 32) i++;
    const val = line.slice(valStart, i);
    if (key === 'phase') phase = val;
    else if (key === 'action') action = val;
    else if (key === 'elapsed_ms') elapsed = val;
    if (phase && action && elapsed) break;
  }
  return { phase, action, elapsed };
}

const rs = fs.createReadStream(input, { encoding: 'utf8', highWaterMark: 1 << 20 });
const rl = readline.createInterface({ input: rs, crlfDelay: Infinity });

rl.on('line', (line) => {
  totalLines++;
  if (line.length === 0) return;
  const { phase, action, elapsed } = parseLine(line);
  if (phase !== 'finish' || !action || elapsed === null) return;
  const ms = Number(elapsed);
  if (!Number.isFinite(ms)) return;
  finishLines++;
  let s = stats.get(action);
  if (!s) {
    s = { count: 0, total: 0, min: Infinity, max: -Infinity };
    stats.set(action, s);
  }
  s.count++;
  s.total += ms;
  if (ms < s.min) s.min = ms;
  if (ms > s.max) s.max = ms;
});

rl.on('close', () => {
  const rows = [];
  for (const [action, s] of stats) {
    rows.push({
      action,
      count: s.count,
      avg_ms: s.count ? s.total / s.count : 0,
      total_ms: s.total,
      min_ms: s.min === Infinity ? 0 : s.min,
      max_ms: s.max === -Infinity ? 0 : s.max,
    });
  }
  rows.sort((a, b) => b.count - a.count);

  const header = 'action,instance_count,avg_elapsed_ms,total_elapsed_ms,min_elapsed_ms,max_elapsed_ms\n';
  const body = rows.map(r =>
    `${csv(r.action)},${r.count},${r.avg_ms.toFixed(3)},${r.total_ms},${r.min_ms},${r.max_ms}`
  ).join('\n') + '\n';
  fs.writeFileSync(output, header + body);

  const elapsedSec = ((Date.now() - startedAt) / 1000).toFixed(1);
  console.error(`parsed ${totalLines.toLocaleString()} lines, ${finishLines.toLocaleString()} finish records, ${rows.length} distinct actions in ${elapsedSec}s`);
  console.error(`wrote ${output}`);

  // Also print a top-15 summary to stdout for quick reading.
  const top = rows.slice(0, 15);
  const w = Math.max(6, ...top.map(r => r.action.length));
  console.log('\nTop 15 by instance count:');
  console.log(`${'action'.padEnd(w)}  ${'count'.padStart(10)}  ${'avg_ms'.padStart(8)}  ${'total_ms'.padStart(10)}  ${'max_ms'.padStart(8)}`);
  for (const r of top) {
    console.log(`${r.action.padEnd(w)}  ${String(r.count).padStart(10)}  ${r.avg_ms.toFixed(3).padStart(8)}  ${String(r.total_ms).padStart(10)}  ${String(r.max_ms).padStart(8)}`);
  }
});

function csv(s) {
  if (/[",\n]/.test(s)) return '"' + s.replace(/"/g, '""') + '"';
  return s;
}
