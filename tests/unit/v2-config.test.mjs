// Release 2.0: one meaning per environment file (bash/python parser == Node parser), deferral of NetFlow and NOC dashboards,
// playlists restricted to what is deployed. Pure unit tests: no network, no Grafana.
import test from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdtempSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseEnv, renderDatasources, flag, datasourceRefs, itemIds, nocTypeRegexes } from '../../scripts/lib/envcfg.mjs';
import { effectiveDashboards, effectivePlaylists } from '../../scripts/lib/content.mjs';
import { repoDashboards } from '../../scripts/lib/grafana.mjs';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const rd = (p) => readFileSync(join(ROOT, p), 'utf8');
const dir = mkdtempSync(join(tmpdir(), 'v2cfg-'));

/** Run lib/envparse.py on text; returns { values, errors, warnings }. */
function py(text) {
  const f = join(dir, 'e.env'); writeFileSync(f, text);
  let raw;
  try { raw = execFileSync('python3', [join(ROOT, 'lib', 'envparse.py'), 'parse', f]); } catch (e) { raw = e.stdout; }
  const parts = raw.toString('utf8').split('\0'); const r = { values: {}, errors: [], warnings: [] };
  for (let i = 0; i < parts.length - 1;) {
    const t = parts[i++];
    if (t === 'V') { r.values[parts[i]] = parts[i + 1]; i += 2; } else if (t === 'E') r.errors.push(parts[i++]); else if (t === 'W') r.warnings.push(parts[i++]); else break;
  }
  return r;
}

// Lines as operators really write them. Bash/python and Node must agree on every one (release 1.x had the bash side drop the first one).
const CORPUS = [
  ['ZABBIX_URL=http://z/api_jsonrpc.php', 'http://z/api_jsonrpc.php'],
  ['  ZABBIX_URL=http://z/api_jsonrpc.php   # temporary, TLS failed', 'http://z/api_jsonrpc.php'],
  ['export ZABBIX_URL="http://z/api_jsonrpc.php" # quoted + comment', 'http://z/api_jsonrpc.php'],
  ["ZABBIX_URL='http://z/a#b'", 'http://z/a#b'],
  ['ZABBIX_URL=http://z/a#b', 'http://z/a#b'],
  ['ZABBIX_URL = http://z/api_jsonrpc.php', 'http://z/api_jsonrpc.php'],
  ['﻿ZABBIX_URL=http://z/api_jsonrpc.php', 'http://z/api_jsonrpc.php'],
  ['ZABBIX_URL=http://z/api_jsonrpc.php ', 'http://z/api_jsonrpc.php'],
  ['ZABBIX_URL=http://z/api_jsonrpc.php\r', 'http://z/api_jsonrpc.php'],
  ['ZABBIX_DS_NAME="Zabbix # prod"', 'Zabbix # prod'],
  ['ZABBIX_CA_FILE=', ''],
  ['ZABBIX_CA_FILE=   # none', ''],
];

test('bash/python and Node parse every corpus line to the same value', () => {
  for (const [line, want] of CORPUS) {
    const key = line.replace(/^﻿/, '').trim().replace(/^export\s+/, '').split('=')[0].trim();
    const p = py(line + '\n');
    assert.deepEqual(p.errors, [], `python errors for ${JSON.stringify(line)}`);
    assert.equal(p.values[key], want, `python value for ${JSON.stringify(line)}`);
    assert.equal(parseEnv(line + '\n')[key], want, `node value for ${JSON.stringify(line)}`);
  }
});

test('yes/no settings accept every common spelling and are normalized', () => {
  for (const v of ['yes', 'YES', 'Yes', 'true', 'True', 'on', '1', '"yes"', "'yes'", 'yes # comment']) assert.equal(py(`ALLOW_INSECURE_DATASOURCES=${v}\n`).values.ALLOW_INSECURE_DATASOURCES, 'yes', v);
  for (const v of ['no', 'NO', 'false', 'off', '0']) assert.equal(py(`ALLOW_INSECURE_DATASOURCES=${v}\n`).values.ALLOW_INSECURE_DATASOURCES, 'no', v);
  assert.equal(py('CLICKHOUSE_SECURE=yes\n').values.CLICKHOUSE_SECURE, 'true', 'true/false settings keep their spelling');
  assert.equal(flag({ X: 'on' }, 'X', false), true);
  assert.equal(flag({}, 'X', true), true);
});

test('misspelled, unknown, duplicate and invalid settings are errors with the reason', () => {
  assert.match(py('ALLOW_INSECURE_DATASOURCE=yes\n').errors[0], /the setting is called ALLOW_INSECURE_DATASOURCES/);
  assert.match(py('ALLOW_INSECURE_DATASOURCEZ=yes\n').errors[0], /did you mean ALLOW_INSECURE_DATASOURCES/);
  assert.match(py('NOT_A_SETTING=1\n').errors[0], /unknown setting NOT_A_SETTING/);
  assert.match(py('ALLOW_INSECURE_DATASOURCES=yes\nALLOW_INSECURE_DATASOURCES=no\n').errors[0], /already set on line 1/);
  assert.match(py('ALLOW_INSECURE_DATASOURCES=maybe\n').errors[0], /must be yes or no/);
  assert.match(py('ALLOW_INSECURE_DATASOURCES=“yes”\n').errors[0], /typographic quote/);
  assert.match(py('GRAFANA_PROTOCOL=ftp\n').errors[0], /must be one of https, http/);
  assert.match(py('GRAFANA_HTTP_PORT=30a0\n').errors[0], /whole number/);
  assert.match(py('ZABBIX_URL="http://z\n').errors[0], /unterminated/);
  assert.match(py('BUNDLE_DIR=$PWD/bundle\n').warnings[0], /NOT expanded/);
  assert.throws(() => parseEnv('A=1\nA=2\n'), /set twice/);
});

test('envparse.py set edits one key in place, keeps comments, refuses invalid results', () => {
  const f = join(dir, 'set.env');
  writeFileSync(f, '# my comment\nGRAFANA_DOMAIN=old\nZABBIX_URL=http://z/api_jsonrpc.php\n');
  execFileSync('python3', [join(ROOT, 'lib', 'envparse.py'), 'set', f, 'GRAFANA_DOMAIN=10.20.8.27', 'GRAFANA_ALLOWED_CIDRS=10.0.0.0/8 10.1.0.0/16', 'ALLOW_INSECURE_DATASOURCES=TRUE']);
  const t = readFileSync(f, 'utf8');
  assert.match(t, /^# my comment$/m);
  assert.match(t, /^GRAFANA_DOMAIN=10\.20\.8\.27$/m);
  assert.match(t, /^GRAFANA_ALLOWED_CIDRS="10\.0\.0\.0\/8 10\.1\.0\.0\/16"$/m);
  assert.match(t, /^ALLOW_INSECURE_DATASOURCES=yes$/m);
  assert.throws(() => execFileSync('python3', [join(ROOT, 'lib', 'envparse.py'), 'set', f, 'ALLOW_INSECURE_DATASOURCE=yes'], { stdio: 'pipe' }));
  assert.equal(readFileSync(f, 'utf8'), t, 'a refused set leaves the file untouched');
});

test('the shipped production template is valid for the parser and lists every setting', () => {
  const p = py(rd('env/production.env.example'));
  assert.deepEqual(p.errors, []);
  const keys = execFileSync('python3', [join(ROOT, 'lib', 'envparse.py'), 'keys']).toString().trim().split('\n').map((l) => l.split(/\s+/)[0]);
  for (const k of keys.filter((k) => !['UPGRADE_AUTO_ROLLBACK', 'PLATFORM_ALLOW_EL_CLONE', 'GRAFANA_ROOT_URL', 'GRAFANA_FIREWALL_ZONE'].includes(k))) assert.ok(k in p.values, `template lacks ${k}`);
});

const ENV = (extra) => ({ PLATFORM_ENV: 'production', ZABBIX_DS_NAME: 'Zabbix', ZABBIX_URL: 'http://z:8080/api_jsonrpc.php', ZABBIX_USER: 'ro', ZABBIX_TLS_SKIP_VERIFY: 'false',
  CLICKHOUSE_HOST: 'ch', CLICKHOUSE_PORT: '8123', CLICKHOUSE_SECURE: 'false', CLICKHOUSE_USER: 'grafana_ro', ...extra });
const NETFLOW = repoDashboards().filter((d) => d.folderDir === 'netflow').map((d) => d.dashboard.uid);
const NOC = repoDashboards().filter((d) => d.folderDir === 'noc').map((d) => d.dashboard.uid);
const LABIDS = JSON.parse(rd('config/zabbix-item-descriptors.json')).items;
const fullMap = Object.fromEntries(Object.keys(LABIDS).map((k, i) => [k, String(900000 + i)]));

test('CLICKHOUSE_ENABLED=no: no ClickHouse datasource (its settings may be empty); NetFlow dashboards deployed with a notice, playlist deferred', () => {
  const env = ENV({ CLICKHOUSE_ENABLED: 'no', CLICKHOUSE_HOST: '', CLICKHOUSE_PORT: '', CLICKHOUSE_USER: '' });
  assert.deepEqual(renderDatasources(env).map((d) => d.uid), ['zabbix-lab']);
  const ctx = { env, envName: 'production', itemMap: fullMap };
  const st = Object.fromEntries(effectiveDashboards(ctx).map((d) => [d.dashboard.uid, d.state]));
  for (const u of NETFLOW) assert.equal(st[u], 'pending', u);
  for (const d of effectiveDashboards(ctx).filter((x) => NETFLOW.includes(x.dashboard.uid))) {
    assert.equal(d.dashboard.panels[0].title, 'Setup still incomplete');
    assert.match(d.dashboard.panels[0].options.content, /setup --clickhouse/);
    assert.deepEqual(datasourceRefs(d.dashboard), ['netflow-clickhouse'], 'datasource reference kept: works once ClickHouse is connected');
  }
  for (const u of NOC) assert.equal(st[u], 'ok', u);
  assert.equal(effectivePlaylists(ctx)[0].state, 'skipped');
  assert.equal(NETFLOW.length, 5);
});

test('CLICKHOUSE_ENABLED=yes (default): both datasources, all dashboards, full playlist', () => {
  const ctx = { env: ENV({}), envName: 'production', itemMap: fullMap };
  assert.deepEqual(renderDatasources(ctx.env).map((d) => d.uid).sort(), ['netflow-clickhouse', 'zabbix-lab']);
  assert.ok(effectiveDashboards(ctx).every((d) => d.state === 'ok'));
  const pl = effectivePlaylists(ctx)[0];
  assert.equal(pl.state, 'ok'); assert.equal(pl.playlist.items.length, 5);
});

test('NOC dashboards are dynamic: no device, host, item, interface or LAB id; Device/Interface come from Zabbix; any item map is irrelevant', () => {
  const LABHOSTS = ['SITE-A', 'SITE-B', 'STC', 'MOBILY', 'INT-CORE', 'SAIX-A', 'SAIX-B'];
  for (const d of repoDashboards().filter((x) => x.folderDir === 'noc')) {
    const txt = JSON.stringify(d.dashboard);
    assert.equal(itemIds(d.dashboard).length, 0, `${d.file}: no item id`);
    assert.ok(!/"itemids"|"hostids"|"queryType":\s*"3"/.test(txt), `${d.file}: no id-based query`);
    for (const h of LABHOSTS) assert.ok(!txt.includes(h), `${d.file}: LAB name ${h}`);
    assert.ok(!Object.keys(LABIDS).some((id) => txt.includes(`"${id}"`)), `${d.file}: LAB item id`);
    const vars = Object.fromEntries(d.dashboard.templating.list.map((v) => [v.name, v]));
    assert.equal(vars.devtype.type, 'custom'); assert.match(vars.devtype.query, /^All : @@NOCQ_ALL@@,Router : @@NOCQ_ROUTER@@,Switch : @@NOCQ_SWITCH@@,Firewall : @@NOCQ_FIREWALL@@$/);
    if (vars.device) {
      assert.deepEqual([vars.device.query.queryType, vars.device.query.group, vars.device.refresh], ['host', '${devtype:raw}', 1], 'Device = Zabbix hosts of the type, refreshed on load');
      assert.deepEqual([vars.interface.query.queryType, vars.interface.query.host], ['itemTag', '$device'], 'Interface = item tags of the device');
      assert.equal(vars.interface.multi, true);
    }
  }
  for (const itemMap of [null, { 51128: '1' }]) {
    const noc = effectiveDashboards({ env: ENV({ CLICKHOUSE_ENABLED: 'no' }), envName: 'production', itemMap }).filter((d) => NOC.includes(d.dashboard.uid));
    assert.ok(noc.every((d) => d.state === 'ok'), 'deployed complete, with or without a LAB item map');
  }
});

test('Device Type renders from NOC_GROUPS_* (defaults when empty); commas survive the custom-variable option list', () => {
  const dh = (env) => effectiveDashboards({ env, envName: 'production', itemMap: null }).find((d) => d.dashboard.uid === 'noc-device-health').dashboard;
  const def = dh(ENV({})).templating.list.find((v) => v.name === 'devtype');
  assert.equal(def.query, 'All : /(?:router|rtr)|(?:switch)|(?:firewall)/i,Router : /router|rtr/i,Switch : /switch/i,Firewall : /firewall/i');
  assert.equal(def.current.value, '/(?:router|rtr)|(?:switch)|(?:firewall)/i');
  const v = dh(ENV({ NOC_GROUPS_ROUTER: '/^(?:Network/Routers|Network/WAN Edge)$/i', NOC_GROUPS_SWITCH: '/sw{1,3}itch/i' })).templating.list.find((x) => x.name === 'devtype');
  assert.match(v.query, /Router : \/\^\(\?:Network\/Routers\|Network\/WAN Edge\)\$\/i,/);
  assert.ok(v.query.includes('Switch : /sw{1\\,3}itch/i'), 'comma escaped for Grafana in the option list: ' + v.query);
  assert.ok(!JSON.stringify(dh(ENV({}))).includes('@@NOC'), 'no placeholder left');
  for (const re of Object.values(nocTypeRegexes(ENV({ NOC_GROUPS_ROUTER: '/^(?:Core \\(DC-1\\) \\[A\\]|a : b)$/i' })))) {
    const m = re.match(/^\/(.*)\/i$/); assert.ok(m, re); new RegExp(m[1], 'i');
  }
});

test('datasourceRefs ignores expressions and finds the real datasources of each folder', () => {
  for (const d of repoDashboards()) {
    const refs = datasourceRefs(d.dashboard);
    assert.ok(!refs.includes('__expr__'));
    assert.deepEqual(refs, [d.folderDir === 'netflow' ? 'netflow-clickhouse' : 'zabbix-lab'], d.file);
  }
});

test('ZABBIX_ENABLED=no: Grafana without Zabbix - no Zabbix datasource, NOC dashboards deployed with a notice, NetFlow unaffected', () => {
  const env = ENV({ ZABBIX_ENABLED: 'no', ZABBIX_URL: '', ZABBIX_USER: '' });
  assert.deepEqual(renderDatasources(env).map((d) => d.uid), ['netflow-clickhouse']);
  const st = Object.fromEntries(effectiveDashboards({ env, envName: 'production', itemMap: fullMap }).map((d) => [d.dashboard.uid, d]));
  for (const u of NOC) { assert.equal(st[u].state, 'pending'); assert.match(st[u].reason, /ZABBIX_ENABLED=no/); }
  for (const u of NETFLOW) assert.equal(st[u].state, 'ok');
  const none = ENV({ ZABBIX_ENABLED: 'no', CLICKHOUSE_ENABLED: 'no', ZABBIX_URL: '', CLICKHOUSE_HOST: '' });
  assert.deepEqual(renderDatasources(none), [], 'base Grafana only');
  assert.equal(py('ZABBIX_ENABLED=off\n').values.ZABBIX_ENABLED, 'no');
});

test('ZABBIX_DATASOURCE_UID: an existing Zabbix datasource is used by the NOC dashboards; the installer neither creates nor changes one', () => {
  const env = ENV({ ZABBIX_DATASOURCE_UID: 'ffk3a9zbx', CLICKHOUSE_ENABLED: 'no' });
  assert.deepEqual(renderDatasources(env).map((d) => d.uid), [], 'no managed Zabbix datasource is rendered');
  const noc = effectiveDashboards({ env, envName: 'production', itemMap: fullMap }).filter((d) => NOC.includes(d.dashboard.uid));
  for (const d of noc) {
    assert.equal(d.state, 'ok');
    assert.deepEqual(datasourceRefs(d.dashboard), ['ffk3a9zbx']);
    assert.ok(!JSON.stringify(d.dashboard).includes('"zabbix-lab"'));
  }
  const off = ENV({ ZABBIX_DATASOURCE_UID: 'ffk3a9zbx', ZABBIX_ENABLED: 'no' });
  assert.ok(effectiveDashboards({ env: off, envName: 'production', itemMap: fullMap }).filter((d) => NOC.includes(d.dashboard.uid)).every((d) => d.state === 'pending'), 'ZABBIX_ENABLED=no still wins');
});
