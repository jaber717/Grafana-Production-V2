// NOC — Command Center: the item-name rules of the fleet table, tested on the committed dashboard JSON (no Grafana, no Zabbix).
// Names are the official Zabbix 7.0 SNMP template item names of several vendors plus names that must NEVER be taken as total CPU / memory %.
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const dash = JSON.parse(readFileSync(new URL('../../dashboards/noc/noc-command-center.json', import.meta.url), 'utf8'));
const table = dash.panels.find((p) => p.id === 10);
const rx = (ref) => { const f = table.targets.find((t) => t.refId === ref).item.filter; const m = /^\/(.*)\/(i?)$/.exec(f); return new RegExp(m[1], m[2]); };

const accept = {
  QC1: ['CPU utilization', 'CPU usage', '#1: CPU utilization', 'MPU Board 0: CPU utilization', 'Management plane: CPU utilization', 'Data plane: CPU utilization',
    'Routing Engine 0: CPU utilization', 'Processor total usage', 'CPU utilisation, %', 'CPU usage (%)', 'Module 1: CPU utilization'],
  QC2: ['CPU idle time, %', 'CPU idle (%)', 'Processor idle percent'],
  QM1: ['Memory utilization', 'Memory usage', 'Memory usage, %', 'Processor: Memory utilization', 'MPU Board 0: Memory utilization', 'I/O: Memory utilization',
    'Routing Engine 0: Memory utilization', 'Used memory, %', 'Memory used (%)'],
  QM2: ['Free memory, %', 'Available memory in %', 'Memory free percent'],
};
const reject = {
  QC1: ['CPU temperature', 'CPU fan speed', 'CPU core 1 utilization', 'CPU core #2 usage', 'CPU load average (1m)', 'CPU interrupt time', 'Fan 1: Fan status', 'Temperature: CPU',
    'CPU utilization threshold', 'Memory utilization', 'Interface Gi0/1: Bits received', 'CPU idle time, %', 'Disk utilization', 'CPU usage (bytes)'],
  QC2: ['CPU utilization', 'CPU idle time', 'Fan idle, %'],
  QM1: ['Memory used', 'Memory used (bytes)', 'Total memory', 'Memory usage (bytes)', 'Memory free, %', 'Memory pool size', 'Disk utilization', 'CPU utilization', 'Swap utilization', 'Memory temperature'],
  QM2: ['Free memory', 'Free memory (bytes)', 'Memory utilization', 'Free disk space, %'],
};

for (const ref of Object.keys(accept)) {
  test(`${ref}: vendor item names are matched`, () => { for (const n of accept[ref]) assert.ok(rx(ref).test(n), `${ref} must match "${n}"`); });
  test(`${ref}: temperature / fan / per-core / bytes / other items are not matched`, () => { for (const n of reject[ref]) assert.ok(!rx(ref).test(n), `${ref} must NOT match "${n}"`); });
}

test('availability items are matched by their exact Zabbix names and by nothing else', () => {
  const exact = { AVI: 'ICMP ping', AVS: 'SNMP agent availability', AVA: 'Zabbix agent availability' };
  for (const [ref, name] of Object.entries(exact)) {
    assert.ok(rx(ref).test(name));
    for (const other of ['ICMP loss', 'ICMP response time', 'Interface Gi0/1: Operational status', 'SNMP traps (fallback)', 'Agent ping', 'ICMP ping check']) assert.ok(!rx(ref).test(other), `${ref} must not match "${other}"`);
  }
});

test('availability weights: ICMP outranks SNMP outranks agent; "unknown" (2) counts for nothing', () => {
  const f = (ref) => Object.fromEntries(table.targets.find((t) => t.refId === ref).functions.map((x) => [x.def.name, x.params[0]]));
  assert.deepEqual([f('AVI').scale, f('AVI').offset], ['200', '-100']);                                   // 1 -> +100, 0 -> -100
  assert.deepEqual([f('AVS').removeAboveValue, f('AVS').scale, f('AVS').offset], ['1', '20', '-10']);    // 1 -> +10, 0 -> -10, 2 dropped
  assert.deepEqual([f('AVA').removeAboveValue, f('AVA').scale, f('AVA').offset], ['1', '2', '-1']);      // 1 -> +1, 0 -> -1, 2 dropped
});

test('idle / free tiers are inverted to used %', () => {
  for (const ref of ['QC2', 'QM2']) { const f = table.targets.find((t) => t.refId === ref).functions; assert.deepEqual(f.filter((x) => ['scale', 'offset'].includes(x.def.name)).map((x) => x.params[0]), ['-1', '100']); }
});

test('the table is sorted by Status ascending (DOWN -100.., UNKNOWN none, UP positive) and has the required columns', () => {
  const t = table.transformations;
  assert.equal(t.find((x) => x.id === 'sortBy').options.sort[0].field, 'Status');
  assert.deepEqual(Object.keys(t.find((x) => x.id === 'organize').options.indexByName), ['host\\col', 'TYP', 'Status', 'CPU', 'Memory']);
});
