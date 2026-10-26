// Environment configuration for the content tooling: parse an env file, render config/datasources.tmpl.json, apply the Zabbix item map.
// Pure functions (no network, no Grafana) so they can be unit-tested (tests/unit/*.test.mjs).
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
import { ROOT } from './grafana.mjs';

/** Parse KEY=VALUE lines (no shell evaluation, no expansion) with the SAME rules as lib/envparse.py (the bash side):
 *  BOM / CRLF / non-breaking spaces tolerated, '#' comment lines, optional 'export ', blanks around '=' allowed,
 *  "double" or 'single' quoted values (only a # comment may follow the closing quote), unquoted values end at a blank-preceded '#'.
 *  grafana-platform hands these tools an already normalized file; this parser stays strict so LAB use behaves identically. */
export function parseEnv(text) {
  const out = {};
  const clean = text.replace(/^\uFEFF/, '').replace(/[\u00A0\u2007\u202F]/g, ' ');
  clean.split(/\r\n|\r|\n/).forEach((raw, i) => {
    const where = `line ${i + 1}`;
    let l = raw.trim();
    if (!l || l.startsWith('#')) return;
    l = l.replace(/^export\s+/, '');
    const eq = l.indexOf('=');
    if (eq < 0) throw new Error(`unparsable line in env file (${where}): ${l.slice(0, 40)}`);
    const key = l.slice(0, eq).trim();
    if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(key)) throw new Error(`unparsable line in env file (${where}): ${l.slice(0, 40)}`);
    if (key in out) throw new Error(`${key} is set twice in the env file (${where})`);
    let v = l.slice(eq + 1).trim();
    if (/^[\u201C\u201D\u2018\u2019\u00AB\u00BB]/.test(v)) throw new Error(`${key}: typographic quote in the env file (${where}); use plain quotes`);
    if (v.startsWith('"') || v.startsWith("'")) {
      const end = v.indexOf(v[0], 1);
      if (end < 0) throw new Error(`${key}: unterminated quote (${where})`);
      const rest = v.slice(end + 1).trim();
      if (rest && !rest.startsWith('#')) throw new Error(`${key}: unexpected text after the closing quote (${where})`);
      v = v.slice(1, end);
    } else {
      v = v.replace(/\s#.*$/, '').trim();
      if (v.startsWith('#')) v = '';
    }
    out[key] = v;
  });
  return out;
}
export function loadEnvFile(path) { return parseEnv(readFileSync(path, 'utf8')); }

export const toBool = (v, name) => { if (/^(true|yes|on|1)$/i.test(String(v).trim())) return true; if (/^(false|no|off|0)$/i.test(String(v).trim())) return false; throw new Error(`${name} must be true/false (got "${v}")`); };
/** A yes/no setting with a default (empty or missing = default). */
export const flag = (env, name, dflt) => (env[name] === undefined || env[name] === '' ? dflt : toBool(env[name], name));

/** Replace "@@NAME@@", "@@NAME:int@@", "@@NAME:bool@@" string values in a parsed JSON structure. Unknown / empty required values throw. */
export function substitute(node, env) {
  if (Array.isArray(node)) return node.map((x) => substitute(x, env));
  if (node && typeof node === 'object') return Object.fromEntries(Object.entries(node).map(([k, v]) => [k, substitute(v, env)]));
  if (typeof node !== 'string') return node;
  const whole = node.match(/^@@([A-Z0-9_]+)(?::(int|bool))?@@$/);
  const get = (name) => { const v = env[name]; if (v === undefined || v === '') throw new Error(`environment value ${name} is required but not set`); return v; };
  if (whole) {
    const v = get(whole[1]);
    if (whole[2] === 'int') { if (!/^\d+$/.test(v)) throw new Error(`${whole[1]} must be an integer (got "${v}")`); return Number(v); }
    if (whole[2] === 'bool') return toBool(v, whole[1]);
    return v;
  }
  return node.replace(/@@([A-Z0-9_]+)@@/g, (_, n) => get(n));
}

/** Datasource uids this environment does not deploy (ZABBIX_ENABLED=no / CLICKHOUSE_ENABLED=no). */
export function deferredDatasources(env) {
  return [...(flag(env, 'ZABBIX_ENABLED', true) ? [] : ['zabbix-lab']), ...(flag(env, 'CLICKHOUSE_ENABLED', true) ? [] : ['netflow-clickhouse'])];
}
// ---- NOC "Device Type" = regex over Zabbix host group names ------------------------------------------------------------
export const NOC_DEFAULT_GROUPS = { ROUTER: '/router|rtr/i', SWITCH: '/switch/i', FIREWALL: '/firewall/i' };
const reEsc = (t) => t.replace(/[.^$*+?()[\]{}|\\]/g, '\\$&');   // metacharacters only: valid in JavaScript AND Go RE2
/** "/body/flags" -> body; a plain value = one literal group name. " : " (Grafana's text/value separator) becomes " \x3A ". */
function regexBody(v) {
  const m = String(v).match(/^\/(.*)\/([gimsuy]*)$/s);
  return (m ? m[1] : reEsc(String(v))).replace(/ : /g, ' \\x3A ');
}
/** { ROUTER, SWITCH, FIREWALL, ALL } as plugin regex filters "/.../i" for the NOC Device Type variable. */
export function nocTypeRegexes(env) {
  const out = {};
  for (const t of ['ROUTER', 'SWITCH', 'FIREWALL']) out[t] = `/${regexBody(String(env[`NOC_GROUPS_${t}`] || '').trim() || NOC_DEFAULT_GROUPS[t])}/i`;
  out.ALL = `/${['ROUTER', 'SWITCH', 'FIREWALL'].map((t) => `(?:${out[t].slice(1, -2)})`).join('|')}/i`;
  return out;
}
/** Copy of `dash` with "@@NOC_<TYPE>@@" replaced by the group regex, and "@@NOCQ_<TYPE>@@" (inside the custom variable's option
 *  list, where "," separates options) by the same regex with "," written as "\," (Grafana turns it back into ","). */
export function renderNocPlaceholders(dash, env) {
  const r = nocTypeRegexes(env);
  return JSON.parse(JSON.stringify(dash), (_k, v) => (typeof v === 'string' && v.includes('@@NOC')
    ? v.replace(/@@NOC(Q?)_(ROUTER|SWITCH|FIREWALL|ALL)@@/g, (_m, q, t) => (q ? r[t].replace(/,/g, '\\,') : r[t])) : v));
}

/** uid of an existing Zabbix datasource the dashboards use instead of the managed 'zabbix-lab' ('' = none). */
export const adoptedZabbixUid = (env) => (flag(env, 'ZABBIX_ENABLED', true) && String(env.ZABBIX_DATASOURCE_UID || '').trim() !== 'zabbix-lab' ? String(env.ZABBIX_DATASOURCE_UID || '').trim() : '');
/** Copy of a dashboard whose references to datasource uid `from` point at `to`. */
export function retargetDatasource(dash, from, to) {
  const copy = JSON.parse(JSON.stringify(dash));
  (function walk(o) {
    if (!o || typeof o !== 'object') return;
    if (o.datasource && typeof o.datasource === 'object' && o.datasource.uid === from) o.datasource.uid = to;
    Object.values(o).forEach(walk);
  })(copy);
  return copy;
}
const ENABLER = { 'zabbix-lab': 'ZABBIX_ENABLED', 'netflow-clickhouse': 'CLICKHOUSE_ENABLED' };
export const deferReason = (uid) => `${ENABLER[uid] || 'configuration'}=no`;

/** config/datasources.tmpl.json rendered with the environment (deferred datasources are left out, so their settings may be empty). */
export function renderDatasources(env, root = ROOT) {
  const off = new Set(deferredDatasources(env));
  if (adoptedZabbixUid(env)) off.add('zabbix-lab');   // an existing Zabbix datasource is used instead: nothing to create or change
  return JSON.parse(readFileSync(join(root, 'config', 'datasources.tmpl.json'), 'utf8')).filter((d) => !off.has(d.uid)).map((d) => substitute(d, { ZABBIX_CACHE_TTL: '5m', ...env, ...(env.ZABBIX_CACHE_TTL ? {} : { ZABBIX_CACHE_TTL: '5m' }) }));
}

/** Every datasource uid a dashboard references (built-in pseudo datasources excluded). */
export function datasourceRefs(dash) {
  const refs = new Set();
  (function walk(o) {
    if (!o || typeof o !== 'object') return;
    if (o.datasource && typeof o.datasource === 'object' && o.datasource.uid) refs.add(o.datasource.uid);
    Object.values(o).forEach(walk);
  })(dash);
  for (const r of [...refs]) if (r === '__expr__' || r === 'grafana' || r.startsWith('-- ') || r.startsWith('${')) refs.delete(r);
  return [...refs];
}

// ---- Zabbix item map ----------------------------------------------------------------------------------------------
/** All "itemids" values (queryType 3) of a dashboard, in order of appearance. */
export function itemIds(dash) {
  const ids = [];
  (function walk(o) {
    if (!o || typeof o !== 'object') return;
    if (typeof o.itemids === 'string' && String(o.queryType) === '3') o.itemids.split(',').map((s) => s.trim()).filter(Boolean).forEach((i) => ids.push(i));
    Object.values(o).forEach(walk);
  })(dash);
  return ids;
}

/** Returns { dashboard, missing:[ids without a mapping], affectedPanels:[titles] }. Does not mutate the input. A null/undefined map = identity (LAB).
 *  blankMissing: an id without a mapping is removed instead of kept (a LAB id must never reach another Zabbix). */
export function applyItemMap(dash, map, { blankMissing = false } = {}) {
  const copy = JSON.parse(JSON.stringify(dash));
  if (!map) return { dashboard: copy, missing: [], affectedPanels: [] };
  const missing = new Set(); const affected = new Set();
  (function walk(o, panel) {
    if (!o || typeof o !== 'object') return;
    const here = o.gridPos && 'type' in o ? o : panel;
    if (typeof o.itemids === 'string' && String(o.queryType) === '3') {
      const out = [];
      for (const i of o.itemids.split(',').map((x) => x.trim()).filter(Boolean)) {
        if (map[i] === undefined || map[i] === '') { missing.add(i); if (here) affected.add(here.title || `panel ${here.id}`); if (!blankMissing) out.push(i); } else out.push(String(map[i]));
      }
      o.itemids = out.join(',');
    }
    Object.values(o).forEach((v) => walk(v, here));
  })(copy, null);
  return { dashboard: copy, missing: [...missing].sort(), affectedPanels: [...affected] };
}

export function loadItemMap(path) {
  if (!path || !existsSync(path)) return null;
  const m = JSON.parse(readFileSync(path, 'utf8'));
  if (!m || typeof m !== 'object' || Array.isArray(m)) throw new Error(`${path}: item map must be a JSON object {"<lab item id>": "<item id here>"}`);
  for (const [k, v] of Object.entries(m)) if (!/^\d+$/.test(k) || !/^\d+$/.test(String(v))) throw new Error(`${path}: bad entry ${k} -> ${v} (ids are numeric)`);
  return m;
}
