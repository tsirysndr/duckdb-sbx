import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { test } from 'node:test';

const bin = resolve('bin/duckdb-sbx.js');
const cli = (args, env = {}) => spawnSync(process.execPath, [bin, ...args], {
  encoding: 'utf8', timeout: 10000, env: { ...process.env, ...env },
});

test('help, version and unsupported options', () => {
  const help = cli(['--help']);
  assert.equal(help.status, 0, help.stderr);
  assert.match(help.stdout, /duckdb-sbx/);
  assert.doesNotMatch(help.stdout, /studio|drizzle|sqlite|postgres/i);
  assert.match(cli(['--version']).stdout, /duckdb-sbx 0.1.0/);
  for (const args of [['start', 'openbsd'], ['start', '--port', '5432'], ['start', '--password', 'secret'], ['studio'], ['drizzle']]) {
    assert.notEqual(cli(args).status, 0, args.join(' '));
  }
});

test('container lifecycle and branch switching through the CLI', () => {
  const dir = mkdtempSync(join(tmpdir(), 'duckdb-sbx-test-'));
  const env = {
    XDG_CONFIG_HOME: join(dir, 'config'), BSDKRUN_NO_AUTO_INSTALL: '1',
    BSDKRUN_BIN: join(dir, 'bsdkrun'), PATH: `${dir}:${process.env.PATH}`,
    SBX_TEST_DIR: dir,
  };
  try {
    // Both external commands are mocked; this test never operates a real VM.
    const fixture = `#!${process.execPath}
import { existsSync, readFileSync, writeFileSync, appendFileSync } from 'node:fs';
import { basename, join } from 'node:path';
const dir = process.env.SBX_TEST_DIR;
const file = join(dir, 'fake.json');
const s = existsSync(file) ? JSON.parse(readFileSync(file)) : { engine: true, volume: false, branches: [], mounted: null, container: null };
const a = process.argv.slice(2), tool = basename(process.argv[1]);
if (a[0] === '--log-level') a.splice(0,2);
appendFileSync(join(dir, 'calls.jsonl'), JSON.stringify({tool, args:a})+'\\n');
const out = x => console.log(JSON.stringify(x));
const status = () => ({running:s.engine, machine_id:'engine', machine_running:s.engine, socket:'/fake/docker.sock', mounts:[]});
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
  else if(a[0]==='run') { if(a.includes('-p')) die(); s.container={id:'container',name:'duckdb-sbx',state:'running',status:'Up'}; }
  else if(a[0]==='rm') s.container=null;
  else if(a[0]==='stop') s.container.state='exited';
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
    run(['start', 'linux', '2.0.0', '--db', 'analytics', '-d']);
    const statePath = join(env.XDG_CONFIG_HOME, 'duckdb-sbx', 'state.json');
    assert.equal(JSON.parse(readFileSync(statePath)).db, 'analytics');
    assert.match(run(['status']).stdout, /ready/);
    assert.match(run(['url']).stdout, /analytics.duckdb/);
    assert.match(run(['start', '-d']).stdout, /already running/);
    run(['exec', 'false'], 9);
    run(['checkout', '-b', 'feature']);
    assert.equal(JSON.parse(readFileSync(statePath)).branch, 'feature');
    run(['checkout', 'main']);
    run(['branch', '-d', 'feature']);
    run(['branch', '-d', 'main'], 1);
    run(['start', 'linux', 'different'], 1);
    run(['stop']);
    run(['start', '-d']);
    run(['destroy', '--yes']);
    assert.equal(JSON.parse(readFileSync(join(dir, 'fake.json'))).volume, false);
    const calls = readFileSync(join(dir, 'calls.jsonl'), 'utf8').trim().split('\n').map(JSON.parse);
    assert(calls.some(c => c.tool === 'docker' && c.args.includes('/mnt/duckdb-sbx-feature:/var/lib/duckdb')));
    assert(calls.some(c => c.tool === 'docker' && c.args.includes(':memory:')));
    run(['start', 'linux', '2.0.0', '--db', '../escape', '-d'], 1);
    run(['start', 'linux', 'bad\nFROM injected', '-d'], 1);
    run(['start', 'linux', '1.4.5', '-d'], 1);
    run(['start', 'linux', 'custom/duckdb:dev', '-d'], 1, { SBX_REPORTED_VERSION: 'v1.5.6' });
    assert.equal(JSON.parse(readFileSync(join(dir, 'fake.json'))).container, null);
    run(['destroy', '--yes']);
    run(['start', '-d'], 1, { SBX_FAIL_BUILD: '1' });
    run(['destroy', '--yes']);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
