import { readFileSync, mkdirSync, cpSync, chmodSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
import { spawnSync } from 'node:child_process';

export const targets = Object.freeze({
  'darwin-aarch64': 'bun-darwin-arm64',
  'linux-x86_64': 'bun-linux-x64-baseline',
  'linux-arm64': 'bun-linux-arm64',
});

export function verifyReleaseVersion(tag, version, cliVersion) {
  if (!/^v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(tag) || tag !== `v${version}`) {
    throw Error(`Release tag must match package.json: v${version}`);
  }
  if (cliVersion.trim() !== `duckdb-sbx ${version}`) throw Error('Main.version and package.json disagree');
}

export function verifyBinary(bytes, platform) {
  if (!Object.hasOwn(targets, platform) || bytes.length < 32) throw Error('Invalid release platform or truncated executable');
  if (platform === 'darwin-aarch64') {
    if (bytes.readUInt32LE(0) !== 0xfeedfacf || bytes.readUInt32LE(4) !== 0x0100000c) throw Error('Expected an arm64 Mach-O executable');
  } else {
    const machine = platform === 'linux-x86_64' ? 62 : 183;
    if (bytes.subarray(0, 4).toString('hex') !== '7f454c46' || bytes[4] !== 2 || bytes[5] !== 1 || bytes.readUInt16LE(18) !== machine) {
      throw Error(`Expected a 64-bit ELF executable for ${platform}`);
    }
  }
}

function command(program, args, capture = false) {
  const r = spawnSync(program, args, { stdio: capture ? 'pipe' : 'inherit', encoding: 'utf8' });
  if (r.error) throw r.error;
  if (r.status !== 0) throw Error(`${program} failed (${r.status}): ${r.stderr ?? ''}`);
  return r.stdout ?? '';
}

export function buildRelease(env = process.env) {
  const platform = env.RELEASE_PLATFORM;
  if (!Object.hasOwn(targets, platform)) throw Error('Set RELEASE_PLATFORM to darwin-aarch64, linux-x86_64 or linux-arm64');
  if (env.BUN_TARGET && env.BUN_TARGET !== targets[platform]) throw Error('BUN_TARGET does not match RELEASE_PLATFORM');
  const { version } = JSON.parse(readFileSync('package.json', 'utf8'));
  verifyReleaseVersion(env.RELEASE_TAG ?? '', version, command(process.execPath, ['bin/duckdb-sbx.js', '--version'], true));
  const staging = resolve('dist/release-build', platform);
  mkdirSync(staging, { recursive: true });
  mkdirSync('dist/release', { recursive: true });
  const executable = resolve(staging, 'duckdb-sbx');
  command('bun', ['build', '--compile', '--minify', '--target', targets[platform], 'bin/duckdb-sbx.js', '--outfile', executable]);
  chmodSync(executable, 0o755);
  verifyBinary(readFileSync(executable), platform);
  const native = (platform === 'darwin-aarch64' && process.platform === 'darwin' && process.arch === 'arm64') ||
    (platform === 'linux-x86_64' && process.platform === 'linux' && process.arch === 'x64') ||
    (platform === 'linux-arm64' && process.platform === 'linux' && process.arch === 'arm64');
  if (native) verifyReleaseVersion(env.RELEASE_TAG, version, command(executable, ['--version'], true));
  for (const file of ['README.md', 'LICENSE']) cpSync(file, resolve(staging, file));
  const archive = resolve('dist/release', `duckdb-sbx-${platform}.tar.gz`);
  command('tar', ['-czf', archive, '-C', staging, 'duckdb-sbx', 'README.md', 'LICENSE']);
  console.log(`Built ${archive}`);
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) buildRelease();
