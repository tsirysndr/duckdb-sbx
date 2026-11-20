import { test, expect } from 'bun:test';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, rmSync, existsSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';

const installer = resolve('install.sh');
function fixture() {
  const root = mkdtempSync(join(tmpdir(), 'duckdb-sbx-installer-test-'));
  const tools = join(root, 'tools'), assets = join(root, 'assets'), payload = join(root, 'payload');
  for (const dir of [tools, assets, payload]) mkdirSync(dir);
  const binary = '#!/bin/sh\nprintf "duckdb-sbx 0.1.0\\n"\n';
  writeFileSync(join(payload, 'duckdb-sbx'), binary, { mode: 0o755 });
  const sums = [];
  for (const platform of ['darwin-aarch64', 'linux-x86_64', 'linux-arm64']) {
    const name = `duckdb-sbx-${platform}.tar.gz`;
    const packed = spawnSync('tar', ['-czf', join(assets, name), '-C', payload, 'duckdb-sbx']);
    if (packed.status !== 0) throw Error('Could not create installer fixture');
    sums.push(`${createHash('sha256').update(readFileSync(join(assets, name))).digest('hex')}  ${name}`);
  }
  writeFileSync(join(assets, 'SHA256SUMS'), sums.join('\n') + '\n');
  writeFileSync(join(tools, 'uname'), `#!${process.execPath}\nconsole.log(process.argv[2] === '-s' ? process.env.MOCK_OS : process.env.MOCK_ARCH);\n`, { mode: 0o755 });
  writeFileSync(join(tools, 'curl'), `#!${process.execPath}
import { copyFileSync, appendFileSync } from 'node:fs';
import { join } from 'node:path';
const args = process.argv.slice(2), url = args.find(x => x.startsWith('https://'));
appendFileSync(join(process.env.MOCK_ROOT, 'requests'), url + '\\n');
const name = url.split('/').pop();
if (name === process.env.MOCK_DOWNLOAD_FAIL) process.exit(22);
copyFileSync(join(process.env.MOCK_ROOT, 'assets', name), args[args.indexOf('-o') + 1]);
`, { mode: 0o755 });
  const destination = join(root, 'binary directory');
  const run = (args = [], env = {}) => spawnSync('/bin/sh', [installer, ...args], {
    encoding: 'utf8', timeout: 10000,
    env: { ...process.env, HOME: join(root, 'home'), PATH: `${tools}:${process.env.PATH}`, MOCK_ROOT: root,
      MOCK_OS: 'Linux', MOCK_ARCH: 'x86_64', DUCKDB_SBX_VERSION: 'latest', DUCKDB_SBX_INSTALL_DIR: destination, ...env },
  });
  return { root, destination, binary, run, cleanup: () => rmSync(root, { recursive: true, force: true }) };
}

test('installer maps all release platforms and aliases and installs executable bytes', () => {
  const f = fixture();
  try {
    for (const [os, arch, platform] of [['Darwin','arm64','darwin-aarch64'], ['Darwin','aarch64','darwin-aarch64'], ['Linux','x86_64','linux-x86_64'], ['Linux','amd64','linux-x86_64'], ['Linux','aarch64','linux-arm64'], ['Linux','arm64','linux-arm64']]) {
      const r = f.run([], { MOCK_OS: os, MOCK_ARCH: arch });
      expect(r.status, r.stderr).toBe(0);
      expect(readFileSync(join(f.destination, 'duckdb-sbx'), 'utf8')).toBe(f.binary);
      expect(statSync(join(f.destination, 'duckdb-sbx')).mode & 0o777).toBe(0o755);
      expect(readFileSync(join(f.root, 'requests'), 'utf8')).toContain(`/releases/latest/download/duckdb-sbx-${platform}.tar.gz`);
    }
  } finally { f.cleanup(); }
});

test('installer supports pinned versions, an environment version and the default install directory', () => {
  const f = fixture();
  try {
    expect(f.run(['0.1.0']).status).toBe(0);
    expect(readFileSync(join(f.root, 'requests'), 'utf8')).toContain('/download/v0.1.0/');
    const r = f.run([], { DUCKDB_SBX_VERSION: 'v0.2.0', DUCKDB_SBX_INSTALL_DIR: '' });
    expect(r.status, r.stderr).toBe(0);
    expect(readFileSync(join(f.root, 'requests'), 'utf8')).toContain('/download/v0.2.0/');
    expect(existsSync(join(f.root, 'home', '.local', 'bin', 'duckdb-sbx'))).toBe(true);
  } finally { f.cleanup(); }
});

test('installer rejects unsupported hosts and malformed versions before downloading', () => {
  const f = fixture();
  try {
    expect(f.run([], { MOCK_OS: 'Darwin', MOCK_ARCH: 'x86_64' }).status).not.toBe(0);
    expect(f.run([], { MOCK_OS: 'FreeBSD', MOCK_ARCH: 'amd64' }).status).not.toBe(0);
    expect(f.run(['../../other']).status).not.toBe(0);
    expect(existsSync(join(f.root, 'requests'))).toBe(false);
    expect(existsSync(f.destination)).toBe(false);
  } finally { f.cleanup(); }
});

test('failed downloads and checksum mismatches preserve an existing installation', () => {
  const f = fixture();
  try {
    mkdirSync(f.destination); const installed = join(f.destination, 'duckdb-sbx');
    writeFileSync(installed, 'existing binary');
    expect(f.run([], { MOCK_DOWNLOAD_FAIL: 'SHA256SUMS' }).status).not.toBe(0);
    expect(readFileSync(installed, 'utf8')).toBe('existing binary');
    writeFileSync(join(f.root, 'assets', 'SHA256SUMS'), `${'0'.repeat(64)}  duckdb-sbx-linux-x86_64.tar.gz\n`);
    const r = f.run();
    expect(r.status).not.toBe(0); expect(r.stderr).toContain('checksum mismatch');
    expect(readFileSync(installed, 'utf8')).toBe('existing binary');
  } finally { f.cleanup(); }
});
