import { async } from '../Bsdkrun.Internal/foreign.js';
import { spawn } from 'node:child_process';
import * as fs from 'node:fs';
import { resolve as absolute, join } from 'node:path';
import { tmpdir } from 'node:os';
import { randomBytes, createHash } from 'node:crypto';
import { createServer } from 'node:net';

export const commandImpl = spec => async(signal => new Promise((resolve, reject) => {
  const child = spawn(spec.program, spec.args, {
    cwd: spec.cwd || undefined, env: { ...process.env, ...spec.env },
    stdio: ['ignore', 'pipe', 'pipe'], detached: process.platform !== 'win32',
  });
  let stdout = '', stderr = '', timedOut = false;
  child.stdout.on('data', chunk => { stdout += chunk; });
  child.stderr.on('data', chunk => { stderr += chunk; });
  const kill = sig => {
    try { process.platform === 'win32' ? child.kill(sig) : process.kill(-child.pid, sig); }
    catch (error) { if (error.code !== 'ESRCH') reject(error); }
  };
  const cancel = () => kill('SIGKILL');
  signal.addEventListener('abort', cancel, { once: true });
  const timer = setTimeout(() => { timedOut = true; kill('SIGKILL'); }, spec.timeout);
  const cleanup = () => { clearTimeout(timer); signal.removeEventListener('abort', cancel); };
  child.on('error', error => { cleanup(); reject(error); });
  child.on('close', code => {
    cleanup();
    if (timedOut) reject(Error(`${spec.program} timed out`));
    else resolve({ code: code ?? 1, stdout, stderr });
  });
}));
export const readText = path => () => fs.readFileSync(path, 'utf8');
export const writeText = path => value => () => fs.writeFileSync(path, value);
export const appendText = path => value => () => fs.appendFileSync(path, value);
export const readBytes = path => () => [...fs.readFileSync(path).subarray(0, 32)];
export const copy = from => to => () => fs.cpSync(from, to, { recursive: true });
export const remove = path => () => fs.rmSync(path, { recursive: true, force: true });
export const mkdir = path => () => fs.mkdirSync(path, { recursive: true });
export const chmod = path => mode => () => fs.chmodSync(path, mode);
export const exists = path => () => fs.existsSync(path);
export const readableWritable = path => () => {
  try { fs.accessSync(path, fs.constants.R_OK | fs.constants.W_OK); return true; } catch { return false; }
};
export const resolve = path => () => absolute(path);
export const tempDir = prefix => () => fs.mkdtempSync(join(tmpdir(), prefix));
export const randomHex = size => () => randomBytes(size).toString('hex');
export const sha256 = path => () => createHash('sha256').update(fs.readFileSync(path)).digest('hex');
export const env = name => () => process.env[name] ?? '';
export const setEnv = name => value => () => { process.env[name] = value; };
export const node = () => process.execPath;
export const platform = () => ({ os: process.platform, arch: process.arch });
export const argv = () => process.argv.slice(2);
export const reservePortImpl = async(signal => new Promise((resolve, reject) => {
  const server = createServer(); server.on('error', reject);
  server.listen(0, '127.0.0.1', () => resolve({ port: server.address().port, handle: server }));
}));
export const closePortImpl = server => async(signal => new Promise((resolve, reject) => {
  server.close(error => error ? reject(error) : resolve());
}));
export const onInterrupt = action => () => {
  const handler = () => action();
  process.once('SIGINT', handler); process.once('SIGTERM', handler);
  return () => { process.removeListener('SIGINT', handler); process.removeListener('SIGTERM', handler); };
};
export const setArgs = args => () => { process.argv.splice(2, process.argv.length - 2, ...args); };
