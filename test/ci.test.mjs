import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { setupEnvironment, persistEnvironment } from '../scripts/ci/github-env.mjs';
import { targets, verifyBinary, verifyReleaseVersion } from '../scripts/ci/release.mjs';

test('setup environment bridge ignores logs and validates the complete result before writing', () => {
  const value = [{ name: 'PATH', value: '/managed/bin:/usr/bin' }, { name: 'BUN_INSTALL', value: '/managed/bun\nextra' }];
  const output = 'tool setup progress\n' + JSON.stringify({ environment: value }, null, 2) + '\n';
  assert.deepEqual(setupEnvironment(output), value);
  const dir = mkdtempSync(join(tmpdir(), 'duckdb-sbx-env-test-'));
  try {
    const file = join(dir, 'github-env'); persistEnvironment(output, file);
    const saved = readFileSync(file, 'utf8');
    assert.match(saved, /PATH<<fluentci_/); assert(saved.includes(value[0].value));
    assert.throws(() => persistEnvironment(JSON.stringify({ environment: [{ name: 'PATH\nINJECTED', value: 'x' }] }), file));
    assert.equal(readFileSync(file, 'utf8'), saved);
    assert.throws(() => setupEnvironment('{"environment":[{"value":"missing-name"}]}'));
    assert.throws(() => setupEnvironment('logs with no typed result'));
    assert.throws(() => setupEnvironment('{"environment":[]}'));
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('release rejects a mismatched tag or embedded CLI version', () => {
  verifyReleaseVersion('v0.1.0', '0.1.0', 'duckdb-sbx 0.1.0\n');
  assert.throws(() => verifyReleaseVersion('v0.2.0', '0.1.0', 'duckdb-sbx 0.1.0'));
  assert.throws(() => verifyReleaseVersion('v0.1.0', '0.1.0', 'duckdb-sbx 0.0.1'));
});

test('release verifies architecture headers for all three requested binaries', () => {
  assert.equal(Object.keys(targets).length, 3);
  const mac = Buffer.alloc(32); mac.writeUInt32LE(0xfeedfacf); mac.writeUInt32LE(0x0100000c, 4);
  verifyBinary(mac, 'darwin-aarch64');
  const elf = Buffer.alloc(32); Buffer.from('7f454c460201', 'hex').copy(elf); elf.writeUInt16LE(62, 18);
  verifyBinary(elf, 'linux-x86_64'); assert.throws(() => verifyBinary(elf, 'linux-arm64'));
  elf.writeUInt16LE(183, 18); verifyBinary(elf, 'linux-arm64');
  assert.throws(() => verifyBinary(mac, 'linux-x86_64'));
});
