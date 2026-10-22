// The installer always talks to the LOCAL Grafana through loopback while keeping the public name (or IP) for Host, SNI and certificate
// verification: Node (scripts/lib/grafana.mjs with GRAFANA_CONNECT_ADDR) and curl (lib/common.sh curl_local: --connect-to "::127.0.0.1:").
// Covers GRAFANA_DOMAIN as a DNS name and as an IP literal, over https with a private CA, and the negative case (wrong name -> refused).
import test from 'node:test';
import assert from 'node:assert/strict';
import { createServer } from 'node:https';
import { execFileSync, execFile } from 'node:child_process';
import { mkdtempSync, readFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const dir = mkdtempSync(join(tmpdir(), 'v2tls-'));
let opensslOk = true;
try {
  execFileSync('openssl', ['req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-days', '2', '-subj', '/CN=grafana.test', '-keyout', join(dir, 'k.pem'), '-out', join(dir, 'c.pem'),
    '-addext', 'subjectAltName=DNS:grafana.test,IP:10.20.8.27'], { stdio: 'ignore' });
} catch { opensslOk = false; }

const server = () => new Promise((resolve) => {
  const seen = [];
  const s = createServer({ key: readFileSync(join(dir, 'k.pem')), cert: readFileSync(join(dir, 'c.pem')) }, (req, res) => {
    seen.push(req.headers.host); res.setHeader('Content-Type', 'application/json'); res.end(JSON.stringify({ database: 'ok', version: 'x' }));
  }).listen(0, '127.0.0.1', () => resolve({ s, port: s.address().port, seen }));
});
const nodeGet = (url) => new Promise((resolve) => execFile(process.execPath, ['--input-type=module', '-e',
  `import { get } from ${JSON.stringify(join(ROOT, 'scripts/lib/grafana.mjs'))}; try { console.log(JSON.stringify(await get('/api/health'))); } catch (e) { console.log('ERR ' + (e.code || e.message)); }`],
  { env: { ...process.env, GRAFANA_URL: url, GRAFANA_USER: 'u', GRAFANA_PASSWORD: 'p', GRAFANA_CONNECT_ADDR: '127.0.0.1', GRAFANA_CA_FILE: join(dir, 'c.pem') }, encoding: 'utf8', timeout: 20000 },
  (_e, out) => resolve(out.trim())));
// async on purpose: a synchronous child would block this process's event loop and the in-process server could never answer
const curlGet = (url) => new Promise((resolve) => execFile('curl', ['-sS', '-m', '10', '--connect-to', '::127.0.0.1:', '--cacert', join(dir, 'c.pem'), url],
  { encoding: 'utf8', env: { ...process.env, HTTPS_PROXY: '', https_proxy: '' } }, (e, out) => resolve(e ? 'ERR ' + e.code : out)));

test('Node: https to the local Grafana by DNS name and by IP literal, verified; wrong name refused', { skip: !opensslOk && 'openssl not available' }, async () => {
  const { s, port, seen } = await server();
  assert.match(await nodeGet(`https://grafana.test:${port}`), /"database":"ok"/);
  assert.match(await nodeGet(`https://10.20.8.27:${port}`), /"database":"ok"/);
  assert.match(await nodeGet(`https://other.test:${port}`), /^ERR /, 'certificate name mismatch must be refused');
  s.closeAllConnections(); s.close();
  assert.ok(seen.includes(`grafana.test:${port}`) && seen.includes(`10.20.8.27:${port}`), 'Host header keeps the public name: ' + seen.join(','));
});

test('curl --connect-to: same three cases', { skip: !opensslOk && 'openssl not available' }, async () => {
  const { s, port } = await server();
  assert.match(await curlGet(`https://grafana.test:${port}/api/health`), /"database":"ok"/);
  assert.match(await curlGet(`https://10.20.8.27:${port}/api/health`), /"database":"ok"/);
  assert.match(await curlGet(`https://other.test:${port}/api/health`), /^ERR /);
  s.closeAllConnections(); s.close();
});
