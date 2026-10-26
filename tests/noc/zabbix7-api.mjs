// TEST ONLY. A Zabbix 7.0 JSON-RPC API stand-in for validating the dynamic NOC dashboards with the REAL Grafana Zabbix plugin.
//   node tests/noc/zabbix7-api.mjs <port> <user> <password-file> [--extra-host]
// Strict like Zabbix 7.0: every request parameter is checked against the 7.0 API reference (unknown parameter -> the same
// "Invalid params." error Zabbix returns), the session goes in the Authorization header, deprecated/removed parameters fail.
// Data: host groups, hosts and items shaped like hosts linked to the official Zabbix 7.0 SNMP templates of FIVE vendors whose item
// keys differ (Cisco IOS, Juniper, Huawei VRP, FortiGate, Palo Alto) + ICMP Ping; interface items come from interface discovery
// with the tags "component: network", "interface: <ifName>", "description: <ifAlias>". One router sits in a group whose name does
// not contain "router" (exercises the Device Type mapping); one Linux server must never appear in the NOC dashboards.
// --extra-host adds a router as if it had just been created in Zabbix (new devices must appear without any change in Grafana).
// GET /__calls returns every method called (and its parameter names).
import { createServer } from 'node:http';
import { readFileSync } from 'node:fs';

const [port, USER, pwFile, ...flags] = process.argv.slice(2);
const PASSWORD = readFileSync(pwFile, 'utf8').trim();

// ---- Zabbix 7.0 API reference: accepted parameters (common get parameters + method-specific) ----
const COMMON = ['countOutput', 'editable', 'excludeSearch', 'filter', 'limit', 'output', 'preservekeys', 'search', 'searchByAny', 'searchWildcardsEnabled', 'sortfield', 'sortorder', 'startSearch'];
const ALLOWED = {
  'hostgroup.get': ['graphids', 'groupids', 'hostids', 'maintenanceids', 'triggerids', 'with_graphs', 'with_graph_prototypes', 'with_hosts', 'with_httptests', 'with_items', 'with_item_prototypes', 'with_simple_graph_item_prototypes', 'with_monitored_hosts', 'with_monitored_httptests', 'with_monitored_items', 'with_monitored_triggers', 'with_simple_graph_items', 'with_triggers', 'selectDiscoveryRule', 'selectDiscoveryRules', 'selectGroupDiscoveries', 'selectHostPrototype', 'selectHosts', 'limitSelects'],
  'host.get': ['groupids', 'dserviceids', 'graphids', 'hostids', 'httptestids', 'interfaceids', 'itemids', 'maintenanceids', 'monitored_hosts', 'proxyids', 'proxy_groupids', 'templated_hosts', 'templateids', 'triggerids', 'with_items', 'with_item_prototypes', 'with_simple_graph_items', 'with_graphs', 'with_graph_prototypes', 'with_httptests', 'with_monitored_httptests', 'with_monitored_items', 'with_monitored_triggers', 'with_simple_graph_item_prototypes', 'with_triggers', 'withProblemsSuppressed', 'evaltype', 'severities', 'tags', 'inheritedTags', 'selectDiscoveries', 'selectDiscoveryRule', 'selectGraphs', 'selectHostDiscovery', 'selectHostGroups', 'selectHttpTests', 'selectInterfaces', 'selectInventory', 'selectItems', 'selectMacros', 'selectParentTemplates', 'selectDashboards', 'selectTags', 'selectInheritedTags', 'selectTriggers', 'selectValueMaps', 'limitSelects', 'searchInventory'],
  'item.get': ['itemids', 'groupids', 'templateids', 'hostids', 'proxyids', 'interfaceids', 'graphids', 'triggerids', 'webitems', 'inherited', 'templated', 'monitored', 'group', 'host', 'evaltype', 'tags', 'with_triggers', 'selectHosts', 'selectInterfaces', 'selectTriggers', 'selectGraphs', 'selectDiscoveryRule', 'selectItemDiscovery', 'selectPreprocessing', 'selectTags', 'selectValueMap', 'limitSelects'],
  'history.get': ['history', 'hostids', 'itemids', 'time_from', 'time_till'],
  'trend.get': ['itemids', 'time_from', 'time_till'],
  'valuemap.get': ['valuemapids', 'selectMappings', 'limitSelects'],
  'usermacro.get': ['globalmacro', 'globalmacroids', 'groupids', 'hostids', 'hostmacroids', 'inherited', 'selectHostGroups', 'selectHosts', 'selectTemplateGroups', 'selectTemplates', 'templated', 'templateids'],
  'proxy.get': ['proxyids', 'proxy_groupids', 'selectAssignedHosts', 'selectHosts', 'selectProxyGroup'],
};
const OUTPUT_ONLY = { 'trend.get': ['itemids', 'time_from', 'time_till', 'countOutput', 'limit', 'output'] };

// ---- inventory ----
const groups = [];
const hosts = [];
const items = [];
const valuemaps = [
  { valuemapid: '1', name: 'Service state', mappings: [{ type: '0', value: '0', newvalue: 'Down' }, { type: '0', value: '1', newvalue: 'Up' }] },
  { valuemapid: '2', name: 'zabbix.host.available', mappings: [{ type: '0', value: '0', newvalue: 'not available' }, { type: '0', value: '1', newvalue: 'available' }, { type: '0', value: '2', newvalue: 'unknown' }] }, // 7.0: 0 not available, 1 available, 2 unknown
  { valuemapid: '3', name: 'IF-MIB::ifOperStatus', mappings: ['up', 'down', 'testing', 'unknown', 'dormant', 'notPresent', 'lowerLayerDown'].map((t, i) => ({ type: '0', value: String(i + 1), newvalue: t })) },
];
const group = (name) => { let g = groups.find((x) => x.name === name); if (!g) { g = { groupid: String(100 + groups.length), name }; groups.push(g); } return g; };
let nextItem = 70001;
function item(h, name, key, vt, tags, extra = {}) {
  items.push({ itemid: String(nextItem++), hostid: h.hostid, name, key_: key, value_type: String(vt), status: '0', state: '0', units: extra.units || '', valuemapid: extra.valuemapid || '0', delay: '1m', tags: tags.map(([tag, value]) => ({ tag, value })), gen: extra.gen || (() => 1) });
}
function host(name, groupNames, profile) {
  const h = { hostid: String(10500 + hosts.length), host: name, name, status: '0', groups: groupNames.map(group), tags: [{ tag: 'site', value: 'RYD' }] };
  hosts.push(h);
  const t = Date.now();
  if (profile.icmp !== false) {
    item(h, 'ICMP ping', 'icmpping', 3, [['component', 'health'], ['component', 'network']], { valuemapid: '1', gen: () => (profile.down ? 0 : 1) });
    item(h, 'ICMP loss', 'icmppingloss', 0, [['component', 'health'], ['component', 'network']], { units: '%', gen: () => (profile.down ? 100 : 0) });
    item(h, 'ICMP response time', 'icmppingsec', 0, [['component', 'health'], ['component', 'network']], { units: 's', gen: (c) => 0.002 + (c % 7) / 1000 });
  }
  item(h, 'SNMP agent availability', 'zabbix[host,snmp,available]', 3, [['component', 'health']], { valuemapid: '2', gen: () => (profile.down ? 0 : 1) });
  item(h, 'Uptime (network)', 'system.net.uptime[sysUpTime.0]', 3, [['component', 'system']], { units: 'uptime', gen: (c) => c - 1700000000 });
  for (const [i, cpu] of profile.cpu.entries()) item(h, cpu.name, cpu.key, 0, [['component', 'cpu']], { units: '%', gen: (c) => cpu.base + ((c / 60 + i) % 11) });
  for (const mem of profile.mem) item(h, mem.name, mem.key, 0, [['component', 'memory']], { units: '%', gen: () => mem.base });
  profile.ifs.forEach(([ifName, alias, oper], idx) => {
    const n = idx + 1; const tags = [['component', 'network'], ['description', alias], ['interface', ifName]];
    const label = `Interface ${ifName}(${alias})`;
    item(h, `${label}: Bits received`, `net.if.in[ifHCInOctets.${n}]`, 3, tags, { units: 'bps', gen: (c) => (oper === 1 ? 2e6 * n + (c % 300) * 1000 : 0) });
    item(h, `${label}: Bits sent`, `net.if.out[ifHCOutOctets.${n}]`, 3, tags, { units: 'bps', gen: (c) => (oper === 1 ? 1e6 * n + (c % 200) * 1000 : 0) });
    item(h, `${label}: Operational status`, `net.if.status[ifOperStatus.${n}]`, 3, tags, { valuemapid: '3', gen: () => oper });
    item(h, `${label}: Inbound packets with errors`, `net.if.in.errors[ifInErrors.${n}]`, 3, tags, { units: 'pps', gen: () => 0 });
    item(h, `${label}: Outbound packets discarded`, `net.if.out.discards[ifOutDiscards.${n}]`, 3, tags, { units: 'pps', gen: () => 0 });
    item(h, `${label}: Speed`, `net.if.speed[ifHighSpeed.${n}]`, 3, tags, { units: 'bps', gen: () => 1e9 });
  });
  return h;
}
const ports = (prefix, count, down = []) => Array.from({ length: count }, (_, i) => [`${prefix}${i + 1}`, i < 2 ? `uplink-${i + 1}` : '', down.includes(i + 1) ? 2 : 1]);
// Cisco IOS by SNMP
host('RYD-RTR-01', ['Network/Routers'], { cpu: [{ name: '#1: CPU utilization', key: 'system.cpu.util[cpmCPUTotal5minRev.1]', base: 22 }], mem: [{ name: 'Processor: Memory utilization', key: 'vm.memory.util[vm.memory.util.1]', base: 41 }], ifs: [['Gi0/0', 'WAN-STC', 1], ['Gi0/1', 'WAN-MOBILY', 1], ['Gi0/2', 'LAN', 1], ['Tu100', 'DMVPN', 7]] });
// Juniper by SNMP
host('RYD-RTR-02', ['Network/Routers'], { cpu: [{ name: 'Routing Engine 0: CPU utilization', key: 'system.cpu.util[jnxOperatingCPU.9.1.0.0]', base: 35 }], mem: [{ name: 'Routing Engine 0: Memory utilization', key: 'vm.memory.util[jnxOperatingBuffer.9.1.0.0]', base: 63 }], ifs: [['ge-0/0/0', 'ISP-SAIX', 1], ['xe-0/1/0', 'CORE', 1], ['ae0', 'BUNDLE', 2]] });
// a router in a group whose name does not say "router"
host('RYD-EDGE-01', ['Network/WAN Edge'], { cpu: [{ name: '#1: CPU utilization', key: 'system.cpu.util[cpmCPUTotal5minRev.1]', base: 12 }], mem: [{ name: 'Processor: Memory utilization', key: 'vm.memory.util[vm.memory.util.1]', base: 30 }], ifs: [['Gi0/0/0', 'INTERNET', 1], ['Gi0/0/1', 'LAN', 1]] });
// Huawei VRP by SNMP (core switch, two CPU boards)
host('RYD-CORE-SW-01', ['Network/Core Switches'], { cpu: [{ name: 'MPU Board 0: CPU utilization', key: 'system.cpu.util[hwEntityCpuUsage.16842753]', base: 18 }, { name: 'MPU Board 1: CPU utilization', key: 'system.cpu.util[hwEntityCpuUsage.16908289]', base: 9 }], mem: [{ name: 'MPU Board 0: Memory utilization', key: 'vm.memory.util[hwEntityMemUsage.16842753]', base: 55 }], ifs: ports('XGigabitEthernet0/0/', 24, [17, 18, 19, 20]) });
// Cisco access switch, SNMP only (no ICMP Ping template)
host('RYD-ACC-SW-07', ['Network/Access Switches'], { icmp: false, cpu: [{ name: '#1: CPU utilization', key: 'system.cpu.util[cpmCPUTotal5minRev.1]', base: 8 }], mem: [{ name: 'Processor: Memory utilization', key: 'vm.memory.util[vm.memory.util.1]', base: 37 }], ifs: ports('Gi1/0/', 48, Array.from({ length: 30 }, (_, i) => i + 19)) });
// FortiGate by SNMP
host('RYD-FW-01', ['Network/Firewalls'], { cpu: [{ name: 'CPU utilization', key: 'system.cpu.util[fgSysCpuUsage.0]', base: 27 }], mem: [{ name: 'Memory utilization', key: 'vm.memory.util[fgSysMemUsage.0]', base: 71 }], ifs: [['port1', 'WAN1', 1], ['port2', 'WAN2', 1], ['internal', 'LAN', 1], ['ssl.root', 'SSL-VPN', 1]] });
// Palo Alto by SNMP (management + data plane), currently unreachable
host('RYD-FW-02', ['Network/Firewalls'], { down: true, cpu: [{ name: 'Management plane: CPU utilization', key: 'system.cpu.util[hrProcessorLoad.1]', base: 15 }, { name: 'Data plane: CPU utilization', key: 'system.cpu.util[hrProcessorLoad.2]', base: 44 }], mem: [{ name: 'Memory utilization', key: 'vm.memory.util[memoryUsedPercentage.0]', base: 52 }], ifs: [['ethernet1/1', 'UNTRUST', 1], ['ethernet1/2', 'TRUST', 1]] });
// never part of the NOC dashboards
host('ryd-app-01', ['Linux servers'], { cpu: [{ name: 'CPU utilization', key: 'system.cpu.util', base: 5 }], mem: [{ name: 'Memory utilization', key: 'vm.memory.utilization', base: 20 }], ifs: [['ens192', '', 1]] });
if (flags.includes('--extra-host')) host('RYD-RTR-03', ['Network/Routers'], { cpu: [{ name: '#1: CPU utilization', key: 'system.cpu.util[cpmCPUTotal5minRev.1]', base: 50 }], mem: [{ name: 'Processor: Memory utilization', key: 'vm.memory.util[vm.memory.util.1]', base: 45 }], ifs: [['Gi0/0', 'NEW-LINK', 1]] });

// ---- helpers ----
const pick = (o, out) => (out === 'extend' || !out ? { ...o } : Object.fromEntries([].concat(out).filter((k) => k in o).map((k) => [k, o[k]])));
const strip = ({ gen, groups: _g, tags: _t, ...rest }) => rest;
const asArr = (v) => (v === undefined || v === null ? null : [].concat(v).map(String));
function matchFilter(o, filter) { return !filter || Object.entries(filter).every(([k, v]) => [].concat(v).map(String).includes(String(o[k]))); }
function matchSearch(o, search, p) { if (!search) return true; const res = Object.entries(search).map(([k, v]) => String(o[k] || '').toLowerCase().includes(String(v).toLowerCase())); return p.searchByAny ? res.some(Boolean) : res.every(Boolean); }
function matchTags(objTags, tags, evaltype) {
  if (!tags || !tags.length) return true;
  const one = (t) => { const op = String(t.operator ?? '0'); const hits = objTags.filter((x) => x.tag === t.tag);
    if (op === '4') return hits.length > 0; if (op === '5') return hits.length === 0;
    if (op === '1') return hits.some((x) => x.value === String(t.value ?? '')); if (op === '0') return hits.some((x) => x.value.toLowerCase().includes(String(t.value ?? '').toLowerCase()));
    throw new Error(`tag operator ${op} not modelled`); };
  return String(evaltype ?? '0') === '2' ? tags.some(one) : Object.values(tags.reduce((a, t) => ((a[t.tag] = a[t.tag] || []).push(t), a), {})).every((same) => same.some(one));
}
function series(it, from, till, step = 60) {
  const out = []; for (let c = Math.ceil(from / step) * step; c <= till; c += step) out.push({ itemid: it.itemid, clock: String(c), value: String(it.gen(c)), ns: '0' }); return out;
}

const sessions = new Set(); const calls = []; const ignoredNull = new Set();
createServer((req, res) => {
  let b = ''; req.on('data', (c) => (b += c)).on('end', () => {
    if (req.url === '/__calls') { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(calls)); return; }
    if (req.url === '/__ignored') { res.writeHead(200, { 'Content-Type': 'application/json' }); res.end(JSON.stringify([...ignoredNull])); return; }
    let q; try { q = JSON.parse(b); } catch { res.writeHead(200); res.end(JSON.stringify({ jsonrpc: '2.0', error: { code: -32700, message: 'Parse error.', data: 'Invalid JSON.' }, id: null })); return; }
    const p = q.params || {}; calls.push({ method: q.method, params: Object.keys(p), raw: q.params });
    const ok = (result) => { res.writeHead(200, { 'Content-Type': 'application/json-rpc' }); res.end(JSON.stringify({ jsonrpc: '2.0', result, id: q.id })); };
    const err = (data, code = -32602, message = 'Invalid params.') => { res.writeHead(200, { 'Content-Type': 'application/json-rpc' }); res.end(JSON.stringify({ jsonrpc: '2.0', error: { code, message, data }, id: q.id })); };
    if (q.method === 'apiinfo.version') return req.headers.authorization ? err('The "apiinfo.version" method must be called without authorization header.') : ok('7.0.30');
    if (q.method === 'user.login') { for (const k of Object.keys(p)) if (!['username', 'password', 'userData'].includes(k)) return err(`Invalid parameter "/": unexpected parameter "${k}".`); if (p.username === USER && p.password === PASSWORD) { const s = 's' + Math.random().toString(16).slice(2); sessions.add(s); return ok(s); } return err('Incorrect user name or password or account is temporarily blocked.'); }
    const tok = (req.headers.authorization || '').replace(/^Bearer /, '') || q.auth;
    if (!sessions.has(tok)) return err('Session terminated, re-login, please.', -32602, 'Invalid params.');
    if (q.method === 'user.logout') { sessions.delete(tok); return ok(true); }
    const allowed = OUTPUT_ONLY[q.method] || (ALLOWED[q.method] ? [...COMMON, ...ALLOWED[q.method]] : null);
    if (!allowed) return err(`Incorrect method "${q.method}".`, -32601, 'Method not found.');
    // A removed parameter sent as null is tolerated (the Grafana Zabbix plugin 6.8 sends "applicationids": null on item.get and is in
    // wide use with Zabbix 7.0, so 7.0 evidently ignores it); any unknown parameter WITH a value is rejected like Zabbix does.
    for (const k of Object.keys(p)) if (!allowed.includes(k)) { if (p[k] === null) { ignoredNull.add(`${q.method}:${k}`); continue; } return err(`Invalid parameter "/": unexpected parameter "${k}".`); }
    try {
      if (q.method === 'hostgroup.get') {
        let gs = groups.filter((g) => (!p.with_hosts || hosts.some((h) => h.groups.includes(g))) && (!asArr(p.groupids) || asArr(p.groupids).includes(g.groupid)) && matchFilter(g, p.filter) && matchSearch(g, p.search, p));
        gs = gs.sort((a, c) => a.name.localeCompare(c.name));
        return ok(gs.map((g) => ({ ...pick(g, p.output), ...(p.selectHosts === 'count' ? { hosts: String(hosts.filter((h) => h.groups.includes(g)).length) } : p.selectHosts ? { hosts: hosts.filter((h) => h.groups.includes(g)).map((h) => pick(strip(h), p.selectHosts)) } : {}) })));
      }
      if (q.method === 'host.get') {
        let hs = hosts.filter((h) => (!asArr(p.groupids) || h.groups.some((g) => asArr(p.groupids).includes(g.groupid))) && (!asArr(p.hostids) || asArr(p.hostids).includes(h.hostid)) && matchFilter(h, p.filter) && matchSearch(h, p.search, p) && matchTags(h.tags, p.tags, p.evaltype));
        if (p.countOutput) return ok(String(hs.length));
        hs = hs.sort((a, c) => a.name.localeCompare(c.name));
        return ok(hs.map((h) => ({ ...pick(strip(h), p.output), ...(p.selectTags ? { tags: h.tags } : {}), ...(p.selectHostGroups ? { hostgroups: h.groups.map((g) => pick(g, p.selectHostGroups)) } : {}) })));
      }
      if (q.method === 'item.get') {
        let its = items.filter((i) => (!asArr(p.itemids) || asArr(p.itemids).includes(i.itemid)) && (!asArr(p.hostids) || asArr(p.hostids).includes(i.hostid))
          && (!asArr(p.groupids) || hosts.find((h) => h.hostid === i.hostid).groups.some((g) => asArr(p.groupids).includes(g.groupid)))
          && matchFilter(i, p.filter) && matchSearch(i, p.search, p) && matchTags(i.tags, p.tags, p.evaltype));
        if (p.countOutput) return ok(String(its.length));
        if (p.sortfield) its = its.sort((a, c) => String(a[[].concat(p.sortfield)[0]]).localeCompare(String(c[[].concat(p.sortfield)[0]])));
        const now = Math.floor(Date.now() / 1000);
        return ok(its.map((i) => ({ ...pick({ ...strip(i), lastclock: String(now - 30), lastvalue: String(i.gen(now - 30)) }, p.output), ...(p.selectTags ? { tags: i.tags } : {}),
          ...(p.selectHosts ? { hosts: [pick(strip(hosts.find((h) => h.hostid === i.hostid)), p.selectHosts)] } : {}) })));
      }
      if (q.method === 'history.get' || q.method === 'trend.get') {
        const ids = asArr(p.itemids) || []; const from = Number(p.time_from || 0); const till = Number(p.time_till || Math.floor(Date.now() / 1000));
        let rows = [];
        for (const i of items.filter((x) => ids.includes(x.itemid) && (q.method === 'trend.get' || String(p.history ?? '3') === x.value_type))) {
          const pts = series(i, Math.max(from, till - 7 * 86400), till, q.method === 'trend.get' ? 3600 : 60);
          rows.push(...(q.method === 'trend.get' ? pts.map((r) => ({ itemid: r.itemid, clock: r.clock, num: '60', value_min: r.value, value_avg: r.value, value_max: r.value })) : pts));
        }
        if (p.limit) rows = rows.slice(0, Number(p.limit));
        return ok(rows);
      }
      if (q.method === 'valuemap.get') return ok(valuemaps.filter((v) => !asArr(p.valuemapids) || asArr(p.valuemapids).includes(v.valuemapid)).map((v) => (p.selectMappings ? v : { valuemapid: v.valuemapid, name: v.name })));
      if (q.method === 'usermacro.get') return ok([]);
      if (q.method === 'proxy.get') return ok([]);
    } catch (e) { return err(String(e.message)); }
    return err(`Incorrect method "${q.method}".`, -32601, 'Method not found.');
  });
}).listen(Number(port), '127.0.0.1', () => console.log(`zabbix7-api on 127.0.0.1:${port}: ${groups.length} host groups, ${hosts.length} hosts, ${items.length} items`));
