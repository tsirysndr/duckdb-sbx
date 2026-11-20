import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync, rmSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { createServer } from 'node:net';
import { once } from 'node:events';
import { test } from 'bun:test';

const bin = resolve('bin/duckdb-sbx.js');
const cli = (args, env = {}) => spawnSync(process.execPath, [bin, ...args], {
  encoding: 'utf8', timeout: 12000, env: { ...process.env, ...env },
});

test('help, version and unsupported options', () => {
  const help = cli(['--help']);
  assert.equal(help.status, 0, help.stderr);
  assert.match(help.stdout, /duckdb-sbx/);
  assert.doesNotMatch(help.stdout, /studio|drizzle|sqlite|postgres/i);
  assert.match(cli(['--version']).stdout, /duckdb-sbx 0.1.0/);
  for (const args of [['start', 'openbsd'], ['start', '--port', '0'], ['start', '--password', 'bad'], ['studio'], ['drizzle']]) {
    assert.notEqual(cli(args).status, 0, args.join(' '));
  }
  const start = cli(['start', '--help']);
  assert.match(start.stdout, /--password/);
  assert.match(start.stdout, /--port/);
});

test('container lifecycle, forwarding, credentials and data branches', async () => {
  const reservation = createServer();
  reservation.listen(0, '127.0.0.1'); await once(reservation, 'listening');
  const port = reservation.address().port;
  await new Promise(resolve => reservation.close(resolve));
  const dir = mkdtempSync(join(tmpdir(), 'duckdb-sbx-test-'));
  const env = {
    XDG_CONFIG_HOME: join(dir, 'config'), BSDKRUN_NO_AUTO_INSTALL: '1',
    BSDKRUN_BIN: join(dir, 'bsdkrun'), PATH: `${dir}:${process.env.PATH}`, SBX_TEST_DIR: dir,
  };
  let occupied;
  try {
    // bsdkrun and Docker are mocked. A tiny TCP listener models the host
    // forward so the real port readiness/collision checks still run.
    const fixture = `#!${process.execPath}
import { existsSync, readFileSync, writeFileSync, appendFileSync } from 'node:fs';
import { basename, join } from 'node:path';
import { spawn } from 'node:child_process';
const dir = process.env.SBX_TEST_DIR;
const file = join(dir, 'fake.json');
const s = existsSync(file) ? JSON.parse(readFileSync(file)) : { engine: true, volume: false, branches: [], mounted: null, container: null };
const a = process.argv.slice(2), tool = basename(process.argv[1]);
if (a[0] === '--log-level') a.splice(0,2);
appendFileSync(join(dir, 'calls.jsonl'), JSON.stringify({tool, args:a})+'\\n');
const out = x => console.log(JSON.stringify(x));
const status = () => ({running:s.engine, machine_id:'engine', machine_running:s.engine, socket:'/fake/docker.sock', mounts:[]});
const stopForward = () => { if(s.forwardPid) { try {process.kill(s.forwardPid);} catch {} s.forwardPid=null; } };
const die = () => { console.error('unexpected command: '+tool+' '+a.join(' ')); process.exit(1); };
if (tool === 'bsdkrun') {
  if(a[0]==='ps' || (a[0]==='volume' && a[1]==='ls')) out([]);
  else if(a[0]==='docker') {
    if(a[1]==='status') out(status());
    else if(a[1]==='start') { s.engine=true; out(status()); }
    else if(a[1]==='stop') s.engine=false;
    else if(a[1]==='ps') out(s.container ? [s.container] : []);
    else die();
  } else if(a[0]==='zfs') {
    if(a[1]==='ls') out(s.volume ? [{name:'duckdb-sbx', path:'/fake', branches:s.branches.map(name=>({name})), attached_to:s.mounted ? [{machine:'engine',machine_name:'bsdkrun-docker',running:s.engine,mounts:[{branch:s.mounted,mountpoint:'/mnt/duckdb-sbx-'+s.mounted}]}] : []}] : []);
    else if(a[1]==='create') s.volume=true;
    else if(a[1]==='attach') s.mounted=a[2].split('@')[1];
    else if(a[1]==='detach') { if(!a[2].includes('@') || a[2].split('@')[1]===s.mounted) s.mounted=null; }
    else if(a[1]==='branch') s.branches.push(a[3]);
    else if(a[1]==='destroy') { if(a[2].includes('@')) s.branches=s.branches.filter(b=>b!==a[2].split('@')[1]); else s.volume=false; }
    else die();
  } else die();
} else {
  if(a[0]==='build') { if(process.env.SBX_FAIL_BUILD) process.exit(7); }
  else if(a[0]==='run') {
    const published=a[a.indexOf('-p')+1]; if(!published?.endsWith(':9494')) die();
    const child=spawn(process.execPath,['-e','require("net").createServer().listen(Number(process.argv[1]),process.argv[2])',published.split(':')[0],process.env.SBX_BIND_ADDRESS||'127.0.0.1'],{stdio:'ignore',detached:true});
    child.unref(); s.forwardPid=child.pid;
    s.container={id:'container',name:'duckdb-sbx',state:'running',status:'Up'};
  }
  else if(a[0]==='rm') {stopForward(); s.container=null;}
  else if(a[0]==='stop') {stopForward(); s.container.state='exited';}
  else if(a[0]==='exec') { if(a.includes('false')) process.exit(9); if(a.includes('SELECT version();')) console.log(process.env.SBX_REPORTED_VERSION || 'v2.0.0'); }
  else die();
}
writeFileSync(file, JSON.stringify(s));
`;
    writeFileSync(join(dir, 'bsdkrun'), fixture, { mode: 0o755 });
    writeFileSync(join(dir, 'docker'), fixture, { mode: 0o755 });
    const run = (args, code = 0, extra = {}) => {
      const r = cli(args, { ...env, ...extra });
      assert.equal(r.status, code, `${args.join(' ')}\n${r.stdout}\n${r.stderr}\n${r.error ?? ''}`);
      return r;
    };
    run(['start', 'linux', '2.0.0', '--db', 'analytics', '--password', 'configured-secret', '--port', String(port), '-d']);
    const statePath = join(env.XDG_CONFIG_HOME, 'duckdb-sbx', 'state.json');
    assert.equal(JSON.parse(readFileSync(statePath)).db, 'analytics');
    assert.equal(statSync(statePath).mode & 0o777, 0o600);
    assert.match(run(['status']).stdout, /ready/);
    assert.equal(run(['url']).stdout.trim(), `quack:127.0.0.1:${port}`);
    assert.equal(run(['token']).stdout.trim(), 'configured-secret');
    run(['duckdb', '-c', 'SELECT 42;']);
    run(['start', '--password', "rotated-'\"-secret", '-d']);
    assert.equal(run(['token']).stdout.trim(), "rotated-'\"-secret");
    assert.match(run(['start', '-d']).stdout, /already running/);
    occupied = createServer(); occupied.listen(0, '127.0.0.1'); await once(occupied, 'listening');
    run(['start', '--port', String(occupied.address().port), '-d'], 1);
    await new Promise(resolve => occupied.close(resolve)); occupied = null;
    run(['exec', 'false'], 9);
    run(['checkout', '-b', 'feature']);
    assert.equal(JSON.parse(readFileSync(statePath)).branch, 'feature');
    run(['checkout', 'main']); run(['branch', '-d', 'feature']); run(['branch', '-d', 'main'], 1);
    run(['start', 'linux', 'different'], 1);
    run(['stop']); run(['start', '-d']);
    // An earlier embedded sandbox used port 0 and an empty password.
    run(['stop']);
    const old = JSON.parse(readFileSync(statePath)); old.port=0; old.password='';
    writeFileSync(statePath,JSON.stringify(old));
    run(['start', '--port', String(port), '-d']);
    assert.match(run(['token']).stdout.trim(), /^[a-f0-9]{64}$/);
    run(['destroy', '--yes']);
    assert.equal(JSON.parse(readFileSync(join(dir, 'fake.json'))).volume, false);
    const calls = readFileSync(join(dir, 'calls.jsonl'), 'utf8').trim().split('\n').map(JSON.parse);
    assert(calls.some(c => c.tool==='docker' && c.args.includes('/mnt/duckdb-sbx-feature:/var/lib/duckdb')));
    assert(calls.some(c => c.tool==='docker' && c.args.includes('duckdb-sbx-client') && c.args.includes('SELECT 42;')));
    assert(calls.some(c => c.tool==='docker' && c.args.includes('SBX_PASSWORD=configured-secret')));
    assert(calls.some(c => c.tool==='bsdkrun' && c.args[0]==='docker' && c.args[1]==='start' && c.args.includes('127.0.0.1')));
    run(['start', '--db', '../escape', '-d'], 1);
    run(['start', 'linux', 'bad\nFROM injected', '-d'], 1); run(['start', 'linux', '1.4.5', '-d'], 1);
    run(['start', 'linux', 'custom/duckdb:dev', '--port', String(port), '-d'], 1, {SBX_REPORTED_VERSION:'v1.5.6'});
    assert.equal(JSON.parse(readFileSync(join(dir, 'fake.json'))).container, null);
    run(['destroy', '--yes']);
    run(['start', '--port', String(port), '-d'], 1, {SBX_BIND_ADDRESS:'0.0.0.0'});
    assert.equal(JSON.parse(readFileSync(join(dir, 'fake.json'))).container, null);
    run(['destroy', '--yes']);
    run(['start', '--port', String(port), '-d'], 1, {SBX_FAIL_BUILD:'1'});
    run(['destroy', '--yes']);
  } finally {
    if(occupied) await new Promise(resolve => occupied.close(resolve));
    try {const s=JSON.parse(readFileSync(join(dir,'fake.json'))); if(s.forwardPid) process.kill(s.forwardPid);} catch {}
    rmSync(dir, {recursive:true,force:true});
  }
});


test('host binding check distinguishes loopback from wildcard listeners', async () => {
  const { loopbackListener } = await import('../output/Sbx.Native/foreign.js');
  for (const [address, expected] of [['127.0.0.1', true], ['0.0.0.0', false]]) {
    const listener = createServer();
    try {
      listener.listen(0, address); await once(listener, 'listening');
      assert.equal(loopbackListener(listener.address().port)(), expected);
    } finally { await new Promise(resolve => listener.close(resolve)); }
  }
});
