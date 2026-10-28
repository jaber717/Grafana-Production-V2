// NOC — Network Traffic: static checks of the committed dashboard JSON (no Grafana, no Zabbix).
import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const D = JSON.parse(readFileSync(new URL('../../dashboards/noc/noc-network-traffic.json', import.meta.url), 'utf8'));
const flat = (ps) => ps.flatMap((p) => [p, ...flat(p.panels || [])]);
const panels = flat(D.panels);
const table = panels.find((p) => p.type === 'table' && p.datasource.type === 'alexanderzobnin-zabbix-datasource');

test('identity, refresh and time range', () => {
  assert.equal(D.uid, 'noc-network-traffic'); assert.equal(D.title, 'NOC — Network Traffic');
  assert.equal(D.refresh, '30s'); assert.ok(D.time.from && D.time.to);
  assert.equal(new Set(panels.map((p) => p.id)).size, panels.length, 'unique panel ids');
});

test('variables: Device Type, Devices (multi, All), Interfaces (multi, All, follows Devices)', () => {
  const v = Object.fromEntries(D.templating.list.map((x) => [x.name, x]));
  assert.deepEqual(Object.keys(v), ['devtype', 'device', 'interface']);
  assert.match(v.devtype.query, /All : .*Router : .*Switch : .*Firewall : /);
  assert.ok(v.device.multi && v.device.includeAll && !v.device.allValue);
  assert.ok(v.interface.multi && v.interface.includeAll && !v.interface.allValue);
  assert.equal(v.interface.query.queryType, 'itemTag'); assert.equal(v.interface.query.host, '$device', 'filtered by the selected devices');
});

test('nothing is hardcoded: every Zabbix query follows the variables, no item id / host / interface name', () => {
  for (const p of panels) for (const t of p.targets || []) {
    if (t.datasource?.uid === '-- Dashboard --') { assert.equal(t.panelId, table.id); continue; }
    assert.equal(t.datasource.uid, 'zabbix-lab'); assert.equal(t.queryType, '0', 'metrics query by item NAME, not by id');
    assert.equal(t.host.filter, '$device'); assert.equal(t.group.filter, '${devtype:raw}'); assert.equal(t.itemTag.filter, '$interface');
    assert.ok(!('itemids' in t));
  }
  const txt = JSON.stringify(D).replace(/@@NOCQ?_[A-Z]+@@/g, '');
  assert.ok(!/\b(Gi\d|Te\d|ethernet\d|port\d|RYD|JED)\b/.test(txt), 'no interface or device names');
});

test('item-name patterns: official "Network interfaces by SNMP" names match; unrelated items do not', () => {
  const rx = (ref) => { const m = /^\/(.*)\/(i?)$/.exec(table.targets.find((t) => t.refId === ref).item.filter); return new RegExp(m[1], m[2]); };
  const names = { RX: 'Interface Gi0/1(WAN): Bits received', TX: 'Interface ethernet1/1(UNTRUST): Bits sent', SPD: 'Interface port1(WAN1): Speed', ST: 'Interface XGigabitEthernet0/0/17(): Operational status' };
  for (const [ref, n] of Object.entries(names)) assert.ok(rx(ref).test(n), `${ref} matches ${n}`);
  assert.ok(!rx('RX').test('Interface Gi0/1(WAN): Bits sent') && !rx('SPD').test('Interface Gi0/1(WAN): Speed of the fan') && !rx('ST').test('Interface Gi0/1(WAN): Admin status'));
});

test('traffic stays positive and totals are summed on a common grid', () => {
  const fns = (t) => t.functions.map((f) => f.def.name);
  const inbound = panels.find((p) => p.title === 'Total inbound').targets[0];
  assert.deepEqual(fns(inbound), ['removeBelowValue', 'groupBy', 'sumSeries', 'setAlias']);
  for (const ref of ['RX', 'TX']) assert.deepEqual(fns(table.targets.find((t) => t.refId === ref)), ['removeBelowValue', 'offset', 'setAlias']);
  assert.equal(panels.find((p) => p.title === 'Total outbound').targets[0].functions[0].params[0], '0');
});

test('detail table: columns, N/A handling and drill-down', () => {
  const org = table.transformations.at(-1).options;
  for (const c of ['Device', 'Interface', 'ST', 'SPD', 'Rx', 'Tx', 'Utilization in', 'Utilization out']) assert.ok(c in org.indexByName, c);
  const calc = table.transformations.filter((t) => t.id === 'calculateField').map((t) => t.options.alias);
  assert.deepEqual(calc, ['Rx', 'Tx', 'SPD2', 'NI', 'NO', 'Utilization in', 'Utilization out']);
  const ov = (n) => table.fieldConfig.overrides.find((o) => o.matcher.options === n).properties;
  for (const n of ['Rx', 'Tx', 'Speed', 'Utilization in', 'Utilization out', 'Status']) assert.ok(JSON.stringify(ov(n)).includes('N/A'), `${n}: N/A mapping`);
  assert.ok(JSON.stringify(ov('Device')).includes('/d/noc-device-health/'), 'device name drills down to Device Health');
});

test('required panels exist', () => {
  const titles = panels.map((p) => p.title).join('|');
  for (const t of ['Total inbound', 'Total outbound', 'Total traffic', 'Inbound by interface', 'Outbound by interface', 'utilization — inbound', 'busiest', 'Interfaces UP', 'Interfaces DOWN', 'Errors and discards', 'Interfaces — detail']) assert.ok(titles.includes(t), t);
});
