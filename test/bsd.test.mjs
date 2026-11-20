import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { test } from 'bun:test';

// Every guest operation goes through an isolated mock binary. No VM is booted.
const fixture = `#!${process.execPath}
import { existsSync, readFileSync, writeFileSync, appendFileSync } from 'node:fs';
import { join } from 'node:path';
const dir=process.env.SBX_TEST_DIR, file=join(dir,'fake.json');
const s=existsSync(file)?JSON.parse(readFileSync(file)):{machine:null,volume:false,branches:[],mounted:null,mountReady:true};
const a=process.argv.slice(2); if(a[0]==='--log-level') a.splice(0,2);
appendFileSync(join(dir,'calls.jsonl'),JSON.stringify(a)+'\\n');
const out=x=>console.log(JSON.stringify(x));
const flag=n=>a[a.indexOf(n)+1];
let code=0;
switch(a[0]) {
 case 'ps': out(s.machine?[s.machine]:[]); break;
 case 'freebsd': case 'netbsd':
  s.machine={id:'0123456789ab',name:'duckdb-sbx',image:a[0],kind:a[0],running:true,exit_code:0,cpus:Number(flag('--cpus')),mem:Number(flag('--mem')),state_dir:dir,ports:[],created_at:0};
  s.mounted=flag('--zfs').split('@')[1].split(':')[0];
  if(process.env.SBX_GROW_REBOOT) s.machine.running=false;
  if(process.env.SBX_ZFS_REBOOT) { s.mountReady=false; if(!process.env.SBX_NO_HOST_MARKER) writeFileSync(join(dir,'zfs-netbsd-ready'),''); }
  console.log(s.machine.id); break;
 case 'start': s.machine.running=true; s.mountReady=true; break;
 case 'stop': s.machine.running=false; break;
 case 'rm': s.machine=null; break;
 case 'update': s.machine.cpus=Number(flag('--cpus')); s.machine.mem=Number(flag('--mem')); break;
 case 'shell': case 'logs': console.log('mock console'); break;
 case 'exec': {
  const command=a.slice(a.indexOf('0123456789ab')+1), script=command.join(' ');
  if(script.includes('mount |') || script.includes('modstat |')) { if(!s.mountReady) code=1; }
  else if(script.includes('SELECT version();')) console.log(process.env.SBX_REPORTED_VERSION || 'v2.0.0');
  else if(script.includes('pkg install') || script.includes('pkg_add duckdb')) { if(process.env.SBX_FAIL_PROVISION) {console.error('package install failed'); code=23;} }
  else if(command.includes('false')) code=9;
  break;
 }
 case 'zfs':
  if(a[1]==='ls') out(s.volume?[{name:'duckdb-sbx',path:'/fake',branches:s.branches.map(name=>({name})),attached_to:s.mounted&&s.machine?[{machine:s.machine.id,machine_name:'duckdb-sbx',running:s.machine.running,mounts:[{branch:s.mounted,mountpoint:'/var/lib/duckdb'}]}]:[]}]:[]);
  else if(a[1]==='create') s.volume=true;
  else if(a[1]==='branch') s.branches.push(a[3]);
  else if(a[1]==='attach') s.mounted=a[2].split('@')[1];
  else if(a[1]==='detach') s.mounted=null;
  else if(a[1]==='destroy') { if(a[2].includes('@')) s.branches=s.branches.filter(b=>b!==a[2].split('@')[1]); else s.volume=false; }
  else code=1;
  break;
 case 'probe': break;
 default: console.error('Unexpected command '+a.join(' ')); code=1;
}
writeFileSync(file,JSON.stringify(s)); process.exitCode=code;
`;

function sandbox(fn) {
  const dir=mkdtempSync(join(tmpdir(),'duckdb-sbx-bsd-test-'));
  const env={ ...process.env, XDG_CONFIG_HOME:join(dir,'config'), BSDKRUN_NO_AUTO_INSTALL:'1', BSDKRUN_BIN:join(dir,'bsdkrun'), SBX_TEST_DIR:dir };
  writeFileSync(env.BSDKRUN_BIN,fixture,{mode:0o755});
  const run=(args,code=0,extra={})=>{
    const r=spawnSync(process.execPath,[resolve('bin/duckdb-sbx.js'),...args],{encoding:'utf8',timeout:15000,env:{...env,...extra}});
    assert.equal(r.status,code,`${args.join(' ')}\n${r.stdout}\n${r.stderr}\n${r.error??''}`);
    return r;
  };
  const state=()=>JSON.parse(readFileSync(join(env.XDG_CONFIG_HOME,'duckdb-sbx/state.json')));
  const fake=()=>JSON.parse(readFileSync(join(dir,'fake.json')));
  const calls=()=>readFileSync(join(dir,'calls.jsonl'),'utf8').trim().split('\n').map(JSON.parse);
  try { fn({dir,run,state,fake,calls}); } finally { rmSync(dir,{recursive:true,force:true}); }
}

for(const os of ['freebsd','netbsd']) {
  test(`${os} lifecycle, package provisioning and data branches`,()=>sandbox(({run,state,fake,calls})=>{
    const release=os==='freebsd'?'15.1':'10.1';
    run(['start',os,release,'--db','analytics','-d']);
    assert.equal(state().os,os); assert.equal(state().version,release);
    assert.match(run(['status']).stdout,/RUNNING/);
    run(['exec','false'],9);
    run(['duckdb']); run(['ssh']); run(['log']); run(['log','--boot']);
    run(['start','linux'],1); run(['start',os,'different'],1);
    run(['checkout','-b','feature']); assert.equal(state().branch,'feature');
    run(['checkout','main']);
    run(['branch','-d','feature']); run(['branch','-d','main'],1);
    run(['stop']); assert.equal(fake().machine.running,false);
    run(['start','--cpus','4','--mem','2048','-d']);
    assert.equal(fake().machine.cpus,4); assert.equal(state().cpus,4);
    run(['checkout','-b','staging']); run(['stop']);
    run(['checkout','staging']); assert.equal(fake().machine.running,false);
    run(['start','-d']); assert.equal(state().branch,'staging');
    run(['destroy','--yes']); assert.equal(fake().machine,null); assert.equal(fake().volume,false);
    const history=calls();
    assert(!history.some(a=>a[0]==='docker'));
    assert(history.some(a=>a[0]==='exec'&&a.join(' ').includes(os==='freebsd'?'pkg install -y duckdb':'pkg_add duckdb')));
    assert(history.some(a=>a[0]==='zfs'&&a[1]==='attach'&&a.includes('duckdb-sbx@feature')));
    const create=history.find(a=>a[0]===os);
    assert(create.includes('--disk-size')); assert(!create.includes('--port'));
  }));
}

test('BSD rejects old DuckDB packages, stops the VM and allows recovery',()=>sandbox(({run,fake})=>{
  const r=run(['start','freebsd','-d'],1,{SBX_REPORTED_VERSION:'v1.5.6'});
  assert.match(r.stderr,/DuckDB >= 2/); assert.equal(fake().machine.running,false);
  run(['start','-d']); run(['destroy','--yes']);
}));

test('NetBSD resumes after a root resize reboot',()=>sandbox(({run,calls})=>{
  run(['start','netbsd','-d'],0,{SBX_GROW_REBOOT:'1'});
  assert(calls().some(a=>a[0]==='start'));
  run(['destroy','--yes']);
}));

test('BSD package installation errors are reported with their output',()=>sandbox(({run})=>{
  const r=run(['start','netbsd','-d'],1,{SBX_FAIL_PROVISION:'1'});
  assert.match(r.stdout,/package install failed/); assert.match(r.stderr,/provisioning failed/);
  run(['destroy','--yes']);
}));


test('NetBSD restarts to load installed ZFS modules',()=>sandbox(({run,calls})=>{
  const r=run(['start','netbsd','-d'],0,{SBX_ZFS_REBOOT:'1'});
  assert.match(r.stdout,/restarting the VM to import the data branch/);
  assert(calls().some(a=>a[0]==='stop'));
  run(['destroy','--yes']);
}));


test('NetBSD detects staged ZFS modules without a host marker',()=>sandbox(({run,calls})=>{
  const r=run(['start','netbsd','-d'],0,{SBX_ZFS_REBOOT:'1',SBX_NO_HOST_MARKER:'1'});
  assert.match(r.stdout,/restarting the VM to import the data branch/);
  assert(calls().some(a=>a[0]==='exec'&&a.join(' ').includes('modules/zfs/zfs.kmod')));
  run(['destroy','--yes']);
}));
