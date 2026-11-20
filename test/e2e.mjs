// Opt-in live test; deliberately excluded from node --test test/*.test.mjs.
import assert from 'node:assert/strict';
import { randomBytes } from 'node:crypto';
import { spawn } from 'node:child_process';
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync, appendFileSync, rmSync, chmodSync } from 'node:fs';
import { createServer } from 'node:net';
import { once } from 'node:events';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const projectVersion = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8')).version;

// Exercise the real app with a unique profile name rather than touching the
// user's duckdb-sbx machine, data volume or configuration.
if (process.argv[2] === '--sandbox-cli') {
  const name = process.env.DUCKDB_SBX_E2E_NAME;
  if (!/^duckdb-sbx-e2e-[a-f0-9]{12}$/.test(name ?? '')) throw Error('Missing isolated E2E sandbox name');
  process.argv.splice(2, 1);
  const [{ runAff_ }, { Left }, { run }, { parseCommand }, { profile }] = await Promise.all([
    import('../output/Effect.Aff/index.js'), import('../output/Data.Either/index.js'),
    import('../output/Sbx.App/index.js'), import('../output/Sbx.Cli/index.js'), import('../output/Sbx.DuckDB/index.js'),
  ]);
  const isolated = { ...profile, tool: name };
  runAff_(result => () => {
    if (result instanceof Left) { console.error(result.value0.message); process.exitCode = 1; }
    else process.exitCode = result.value0;
  })(run(isolated)(parseCommand(isolated)(projectVersion)()))();
} else {
  await liveTest();
}

async function freePort() {
  const server = createServer(); server.listen(0, '127.0.0.1');
  await once(server, 'listening'); const port = server.address().port;
  await new Promise(resolve => server.close(resolve)); return port;
}

async function liveTest() {
  const name = `duckdb-sbx-e2e-${randomBytes(6).toString('hex')}`;
  const scratch = mkdtempSync(join(tmpdir(), 'duckdb-sbx-e2e-'));
  const logDir = resolve(process.env.DUCKDB_SBX_E2E_LOG_DIR ?? '.fluentci/test-logs');
  mkdirSync(logDir, { recursive: true });
  const log = join(logDir, 'e2e.log'); writeFileSync(log, '');
  const env = { ...process.env, XDG_CONFIG_HOME: join(scratch, 'config'), DUCKDB_SBX_E2E_NAME: name, NO_COLOR: '1', BSDKRUN_NO_AUTO_INSTALL: '1' };
  const bsdkrun = process.env.BSDKRUN_BIN || 'bsdkrun';
  let engineWasRunning = true, started = false, occupied, failed;
  const pass = message => { console.log(`PASS: ${message}`); appendFileSync(log, `PASS: ${message}\n`); };
  const state = () => JSON.parse(readFileSync(join(env.XDG_CONFIG_HOME, name, 'state.json'), 'utf8'));
  const cancellation = new AbortController();
  const cancel = () => cancellation.abort();
  process.once('SIGINT', cancel); process.once('SIGTERM', cancel);

  async function command(program, args, options = {}) {
    const { allowFailure = false, secretOutput = false, timeout = 300000, cleanup = false, extraEnv = {} } = options;
    const safeArgs = args.map((a, i) => args[i - 1] === '--password' ? '<redacted>' : a);
    if (!secretOutput) appendFileSync(log, `$ ${program} ${safeArgs.join(' ')}\n`);
    const child = spawn(program, args, { env: { ...env, ...extraEnv }, stdio: ['ignore', 'pipe', 'pipe'], detached: process.platform !== 'win32' });
    let stdout = '', stderr = '', timedOut = false;
    child.stdout.on('data', b => { stdout += b; }); child.stderr.on('data', b => { stderr += b; });
    const terminate = signal => {
      try {
        if (process.platform !== 'win32') process.kill(-child.pid, signal);
        else child.kill(signal);
      } catch (error) { if (error.code !== 'ESRCH') throw error; }
    };
    const kill = () => terminate('SIGTERM');
    if (!cleanup) cancellation.signal.addEventListener('abort', kill, { once: true });
    const timer = setTimeout(() => { timedOut = true; terminate('SIGKILL'); }, timeout);
    let code;
    try { [code] = await once(child, 'close'); }
    finally { clearTimeout(timer); cancellation.signal.removeEventListener('abort', kill); }
    if (!secretOutput) appendFileSync(log, stdout + stderr);
    if (timedOut) throw Error(`${program} timed out`);
    if (!cleanup && cancellation.signal.aborted) throw Error('E2E run interrupted');
    if (!allowFailure && code !== 0) throw Error(`${program} failed (${code}): ${stderr}`);
    return { code, stdout, stderr };
  }
  const cli = (args, options = {}) => command(process.execPath, [fileURLToPath(import.meta.url), '--sandbox-cli', ...args], options);

  try {
    const before = await command(bsdkrun, ['docker', 'status', '--json']);
    engineWasRunning = JSON.parse(before.stdout.trim().split('\n').at(-1)).running;
    await command(bsdkrun, ['probe']);
    const machines = JSON.parse((await command(bsdkrun, ['ps', '--all', '--json'])).stdout);
    const volumes = JSON.parse((await command(bsdkrun, ['zfs', 'ls', '--json'])).stdout);
    assert(!machines.some(m => m.name === name) && !volumes.some(v => v.name === name));
    // Check the compiled executable too. The live commands below use the same
    // product modules with the unique name, so existing personal data is safe.
    const binary = await command(resolve('dist/duckdb-sbx'), ['--version']);
    assert.equal(binary.stdout.trim(), `duckdb-sbx ${projectVersion}`);

    const platform = process.platform === 'darwin' ? 'osx' : process.platform;
    const arch = process.arch === 'x64' ? 'amd64' : process.arch;
    assert(['linux-amd64', 'linux-arm64', 'osx-arm64'].includes(`${platform}-${arch}`), 'Unsupported E2E host');
    const clientDir = join(scratch, 'client'); mkdirSync(clientDir);
    await command('curl', ['--fail', '--show-error', '--silent', '--location', '--retry', '3', `https://github.com/duckdb/duckdb/releases/download/v2.0.0/duckdb-cli-${platform}-${arch}.tar.gz`, '-o', join(scratch, 'client.tar.gz')]);
    await command('tar', ['-xzf', join(scratch, 'client.tar.gz'), '-C', clientDir]);
    const client = join(clientDir, 'duckdb'); chmodSync(client, 0o755);
    const initialPassword = `e2e-${randomBytes(24).toString('hex')}`;
    const port = await freePort();
    started = true; // Even failed startup can create a volume that needs cleanup.
    await cli(['start', 'linux', '2.0.0', '--password', initialPassword, '--port', String(port), '-d']);
    const endpoint = async () => (await cli(['url'])).stdout.trim();
    assert.equal(await endpoint(), `quack:127.0.0.1:${port}`);
    assert.equal((await cli(['token'], { secretOutput: true })).stdout.trim(), initialPassword);

    async function query(sql, password = state().password, reject = false) {
      const uri = await endpoint();
      assert.match(uri, /^quack:127\.0\.0\.1:\d+$/);
      const setup = `ATTACH '${uri}' AS sandbox (TOKEN getenv('DUCKDB_SBX_E2E_PASSWORD')); CONNECT sandbox;`;
      const r = await command(client, [':memory:', '-no-agent', '-no-init', '-bail', '-noheader', '-csv', '-cmd', setup, '-c', sql], {
        extraEnv: { DUCKDB_SBX_E2E_PASSWORD: password }, allowFailure: reject, timeout: 120000,
      });
      if (reject) assert.notEqual(r.code, 0, 'Incorrect password was accepted');
      return r.stdout.trim();
    }
    assert.equal(await query('SELECT version();'), 'v2.0.0');
    assert.equal(await query('SELECT 42;'), '42');
    await query('SELECT 1;', 'wrong-password', true);
    pass('host Quack client authenticated; incorrect password rejected');
    await query('CREATE TABLE e2e_values AS SELECT 42 AS n;');
    assert.equal((await cli(['duckdb', '-noheader', '-csv', '-c', 'SELECT n FROM e2e_values;'])).stdout.trim(), '42');
    await cli(['checkout', '-b', 'feature']); await query('UPDATE e2e_values SET n=7;');
    assert.equal(await query('SELECT n FROM e2e_values;'), '7');
    await cli(['checkout', 'main']); assert.equal(await query('SELECT n FROM e2e_values;'), '42');
    await cli(['branch', '-d', 'feature']);
    pass('ZFS branch writes are isolated and main retains its data');

    occupied = createServer(); occupied.listen(0, '127.0.0.1'); await once(occupied, 'listening');
    const collision = await cli(['start', '--port', String(occupied.address().port), '-d'], { allowFailure: true });
    assert.notEqual(collision.code, 0); assert.equal(await query('SELECT n FROM e2e_values;'), '42');
    await new Promise(resolve => occupied.close(resolve)); occupied = null;
    pass('port collision preserves the running server');
    const nextPort = await freePort(); const rotated = `quoted-'"-${randomBytes(24).toString('hex')}`;
    await cli(['start', '--port', String(nextPort), '--password', rotated, '-d']);
    assert.equal(await endpoint(), `quack:127.0.0.1:${nextPort}`);
    assert.equal(await query('SELECT n FROM e2e_values;'), '42'); await query('SELECT 1;', initialPassword, true);
    await cli(['stop']); assert.match((await cli(['status'])).stdout, /STOPPED/);
    await cli(['start', '-d']); assert.equal(await query('SELECT n FROM e2e_values;'), '42');
    assert.equal(state().password, rotated);
    const serverLog = await cli(['log']); assert(!serverLog.stdout.includes(rotated));
    pass('quoted password rotation, port change and stop/start preserve data and credentials');
    writeFileSync(join(logDir, 'result.json'), JSON.stringify({ passed: true, sandbox: name }, null, 2) + '\n');
  } catch (error) {
    failed = error; console.error(error.message); appendFileSync(log, `FAIL: ${error.message}\n`);
  } finally {
    if (occupied) await new Promise(resolve => occupied.close(resolve));
    try {
      await command(bsdkrun, ['ps', '--all', '--json'], { allowFailure: true, cleanup: true, timeout: 15000 });
      if (started) {
        await cli(['log'], { allowFailure: true, cleanup: true, timeout: 15000 });
        await cli(['destroy', '--yes'], { cleanup: true, timeout: 120000 });
      }
      const after = JSON.parse((await command(bsdkrun, ['zfs', 'ls', '--json'], { cleanup: true })).stdout);
      assert(!after.some(v => v.name === name), 'E2E data volume leaked');
      if (!engineWasRunning) {
        const running = JSON.parse((await command(bsdkrun, ['docker', 'ps', '--json'], { cleanup: true })).stdout.trim().split('\n').at(-1));
        if (running.length === 0) await command(bsdkrun, ['docker', 'stop'], { cleanup: true });
      }
      pass('temporary sandbox removed; existing engine/services preserved');
    } catch (cleanupError) {
      failed ??= cleanupError; appendFileSync(log, `CLEANUP FAILED: ${cleanupError.message}\n`);
    }
    process.removeListener('SIGINT', cancel); process.removeListener('SIGTERM', cancel);
    rmSync(scratch, { recursive: true, force: true });
  }
  if (failed) { writeFileSync(join(logDir, 'result.json'), JSON.stringify({ passed: false, error: failed.message }, null, 2) + '\n'); throw failed; }
}
