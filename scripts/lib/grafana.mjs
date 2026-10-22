// Shared helpers for the Grafana tooling. Node >= 18, no dependencies.
// Credentials come ONLY from the environment (never from files in this repository, never printed):
//   GRAFANA_URL                  default http://127.0.0.1:3000
//   GRAFANA_TOKEN                service-account / API token (preferred), OR
//   GRAFANA_USER + GRAFANA_PASSWORD
import { readFileSync, readdirSync, statSync } from 'node:fs';
import http from 'node:http';
import https from 'node:https';
import tls from 'node:tls';
import net from 'node:net';
import { createHash } from 'node:crypto';
import { join, dirname, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

export const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
export const URL_ = (process.env.GRAFANA_URL || 'http://127.0.0.1:3000').replace(/\/$/, '');

export function authHeaders() {
  const h = { 'Content-Type': 'application/json', Accept: 'application/json' };
  if (process.env.GRAFANA_TOKEN) h.Authorization = `Bearer ${process.env.GRAFANA_TOKEN}`;
  else if (process.env.GRAFANA_USER) h.Authorization = 'Basic ' + Buffer.from(`${process.env.GRAFANA_USER}:${process.env.GRAFANA_PASSWORD || ''}`).toString('base64');
  else fail('Set GRAFANA_TOKEN, or GRAFANA_USER and GRAFANA_PASSWORD (environment only).', 2);
  return h;
}

export function fail(msg, code = 1) { console.error('ERROR: ' + msg); process.exit(code); }

export class ApiError extends Error { constructor(method, path, status, body) { super(`${method} ${path} -> ${status} ${String(body).slice(0, 300)}`); this.status = status; } }

// HTTP(S) transport. Honours two optional environment variables for TLS deployments:
//   GRAFANA_CA_FILE        PEM bundle trusted IN ADDITION to the system store (Node's default roots are kept)
//   GRAFANA_CONNECT_ADDR   connect to this address while keeping the URL's host name for the Host header, SNI and certificate
//                          verification (used by grafana-platform to talk to the local instance by its public certificate name)
function request(method, url, headers, body) {
  const u = new URL(url);
  const lib = u.protocol === 'https:' ? https : http;
  const opts = { method, headers: { ...headers, ...(body !== undefined ? { 'Content-Length': Buffer.byteLength(body) } : {}) }, timeout: 60000 };
  if (u.protocol === 'https:') {
    opts.servername = u.hostname;
    if (process.env.GRAFANA_CA_FILE) opts.ca = [...tls.rootCertificates, readFileSync(process.env.GRAFANA_CA_FILE, 'utf8')];
  }
  let target = u;
  if (process.env.GRAFANA_CONNECT_ADDR) {
    // connect to this address whether GRAFANA_DOMAIN is a name or an IP literal (a lookup override alone is skipped for IP literals);
    // the Host header, SNI and the certificate check keep using the public name/IP of the URL
    target = new URL(u); target.hostname = process.env.GRAFANA_CONNECT_ADDR.includes(':') ? `[${process.env.GRAFANA_CONNECT_ADDR}]` : process.env.GRAFANA_CONNECT_ADDR;
    opts.headers.Host = u.host;
    if (u.protocol === 'https:') {
      if (net.isIP(u.hostname)) delete opts.servername;
      opts.checkServerIdentity = (_h, cert) => tls.checkServerIdentity(u.hostname.replace(/^\[|\]$/g, ''), cert);
    }
  }
  return new Promise((resolve, reject) => {
    const req = lib.request(target, opts, (res) => { const chunks = []; res.on('data', (c) => chunks.push(c)); res.on('end', () => resolve({ status: res.statusCode, text: Buffer.concat(chunks).toString('utf8') })); });
    req.on('timeout', () => req.destroy(new Error('request timed out')));
    req.on('error', reject);
    if (body !== undefined) req.write(body);
    req.end();
  });
}

export async function api(method, path, body, { allow404 = false } = {}) {
  const r = await request(method, URL_ + path, authHeaders(), body === undefined ? undefined : JSON.stringify(body));
  let json; try { json = r.text ? JSON.parse(r.text) : null; } catch { json = r.text; }
  if (r.status === 404 && allow404) return null;
  if (r.status < 200 || r.status >= 300) throw new ApiError(method, path, r.status, r.text);
  return json;
}
export const get = (path, opts) => api('GET', path, undefined, opts);

// ---- canonical forms ---------------------------------------------------------------------------------------
export function sortKeys(o) {
  if (Array.isArray(o)) return o.map(sortKeys);
  if (o && typeof o === 'object') return Object.fromEntries(Object.keys(o).sort().map((k) => [k, sortKeys(o[k])]));
  return o;
}
/** A dashboard as it is compared and stored: instance-specific `id` and `version` removed, keys sorted. */
export function normalizeDashboard(d) {
  const c = JSON.parse(JSON.stringify(d));
  delete c.id; delete c.version;
  return sortKeys(c);
}
export const canonical = (o) => JSON.stringify(sortKeys(o));
export const sha256 = (s) => createHash('sha256').update(s).digest('hex');

// ---- repository content ----------------------------------------------------------------------------------
export const readJson = (rel) => JSON.parse(readFileSync(join(ROOT, rel), 'utf8'));

/** [{ file, folderDir, dashboard }] for every dashboards/<folder-dir>/*.json */
export function repoDashboards() {
  const out = [];
  const base = join(ROOT, 'dashboards');
  for (const dir of readdirSync(base).sort()) {
    const p = join(base, dir);
    if (!statSync(p).isDirectory()) continue;
    for (const f of readdirSync(p).filter((x) => x.endsWith('.json')).sort()) {
      const file = relative(ROOT, join(p, f)).replaceAll('\\', '/');
      out.push({ file, folderDir: dir, dashboard: JSON.parse(readFileSync(join(p, f), 'utf8')) });
    }
  }
  return out;
}

/** Parse plugins/plugins.txt -> [{id, version}] ("id version" per line, # comments). */
export function repoPlugins() {
  return readFileSync(join(ROOT, 'plugins', 'plugins.txt'), 'utf8').split(/\r?\n/).map((l) => l.replace(/#.*/, '').trim()).filter(Boolean)
    .map((l) => { const [id, version] = l.split(/\s+/); return { id, version }; });
}

/** Datasource definition equality on the fields this repository manages. */
export function dsComparable(ds) {
  return sortKeys({ name: ds.name, type: ds.type, access: ds.access, url: ds.url || '', isDefault: !!ds.isDefault, basicAuth: !!ds.basicAuth, jsonData: ds.jsonData || {} });
}

export function parseArgs(argv) {
  const a = { _: [] };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i];
    if (t.startsWith('--')) { const k = t.slice(2); const n = argv[i + 1]; if (n !== undefined && !n.startsWith('--')) { a[k] = n; i++; } else a[k] = true; } else a._.push(t);
  }
  return a;
}
export const stamp = () => new Date().toISOString().replace(/[-:]/g, '').replace(/\.\d+Z$/, 'Z');
