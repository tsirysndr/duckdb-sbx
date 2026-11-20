import { randomBytes } from "node:crypto";
import { execFileSync } from "node:child_process";
import { createInterface } from "node:readline";
import { spawn, execFile } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, writeFileSync, rmSync, chmodSync, readdirSync } from "node:fs";
import { dirname } from "node:path";
import { homedir } from "node:os";
import { join, delimiter } from "node:path";
import { fileURLToPath } from "node:url";
import { async } from "../Bsdkrun.Internal/foreign.js";

export const confirmImpl = question => async(signal => new Promise(resolve => {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  rl.question(question, answer => { rl.close(); resolve(/^y(es)?$/i.test(answer.trim())); });
  signal.addEventListener("abort", () => { rl.close(); resolve(false); });
}));

export const spawnInheritImpl = cmd => args => env => cwd => async(signal => new Promise((resolve, reject) => {
  const child = spawn(cmd, args, { stdio: "inherit", env: { ...process.env, ...env }, cwd: cwd ?? undefined });
  signal.addEventListener("abort", () => child.kill());
  child.on("error", reject);
  child.on("exit", (code, sig) => resolve(code ?? (sig ? 128 : 1)));
}));

export const isTty = () => Boolean(process.stdin.isTTY && process.stdout.isTTY);
export const randomPassword = () => randomBytes(32).toString("hex");
// Inspect the actual host listener, including engines started outside sbx.
// A Linux /proc entry is little endian per 32-bit word; macOS provides lsof.
export const loopbackListener = port => () => {
  if (process.platform === "linux") {
    const listeners = [];
    for (const path of ["/proc/net/tcp", "/proc/net/tcp6"]) {
      if (!existsSync(path)) continue;
      for (const line of readFileSync(path, "utf8").trim().split("\n").slice(1)) {
        const fields = line.trim().split(/\s+/);
        const [address, hexPort] = fields[1].split(":");
        if (fields[3] === "0A" && parseInt(hexPort, 16) === port) listeners.push(address);
      }
    }
    return listeners.length > 0 && listeners.every(a =>
      (a.length === 8 && a.endsWith("7F")) || a === "00000000000000000000000001000000");
  }
  const output = execFileSync("lsof", ["-nP", "-a", `-iTCP:${port}`, "-sTCP:LISTEN", "-Fn"], { encoding: "utf8" });
  const addresses = output.split("\n").filter(l => l.startsWith("n")).map(l => l.slice(1));
  return addresses.length > 0 && addresses.every(a => /^127\.\d+\.\d+\.\d+:\d+$/.test(a) || a === `[::1]:${port}`);
};
export const nodeVersion = () => process.version;
export const nodePath = () => process.execPath;
export const configDir = tool => () => {
  const dir = join(process.env.XDG_CONFIG_HOME || join(homedir(), ".config"), tool);
  mkdirSync(dir, { recursive: true });
  return dir;
};
// output/Sbx.Native/foreign.js -> the package root.
export const toolRoot = () => fileURLToPath(new URL("../../", import.meta.url));
export const cwd = () => process.cwd();
export const pathJoin = a => b => join(a, b);
export const readJson = path => () => {
  try { return JSON.parse(readFileSync(path, "utf8")); } catch { return null; }
};
export const writeJson = path => value => () => { writeFileSync(path, JSON.stringify(value, null, 2) + "\n", { mode: 0o600 }); chmodSync(path, 0o600); };
export const writeText = path => text => () => writeFileSync(path, text);
export const removeFile = path => () => rmSync(path, { force: true });
export const fileExists = path => () => existsSync(path);
export const encodeURIComponent = s => globalThis.encodeURIComponent(s);
export const writeStdout = bytes => () => { process.stdout.write(bytes); };
export const writeStderr = bytes => () => { process.stderr.write(bytes); };
export const findExecutable = name => () => {
  for (const dir of (process.env.PATH || "").split(delimiter)) {
    if (dir && existsSync(join(dir, name))) return join(dir, name);
  }
  return null;
};
export const captureImpl = cmd => args => async(signal => new Promise(resolve => {
  execFile(cmd, args, { signal, maxBuffer: 16 * 1024 * 1024 }, (err, stdout, stderr) =>
    resolve({ stdout: String(stdout ?? ""), stderr: String(stderr ?? err?.message ?? ""), exitCode: err ? (typeof err.code === "number" ? err.code : 1) : 0 }));
}));
export const fetchTextImpl = url => async(async signal => {
  const res = await fetch(url, { signal, headers: { "user-agent": "db-sbx" } });
  if (!res.ok) throw new Error(`GET ${url}: ${res.status} ${res.statusText}`);
  return res.text();
});
export const downloadImpl = url => dest => async(async signal => {
  const res = await fetch(url, { signal, headers: { "user-agent": "db-sbx" } });
  if (!res.ok) throw new Error(`GET ${url}: ${res.status} ${res.statusText}`);
  mkdirSync(dirname(dest), { recursive: true });
  writeFileSync(dest, Buffer.from(await res.arrayBuffer()));
  chmodSync(dest, 0o755);
});
export const homeDir = () => homedir();
export const mkdirp = dir => () => { mkdirSync(dir, { recursive: true }); };
export const platform = () => ({
  os: process.platform === "darwin" ? "macos" : process.platform === "win32" ? "win" : "linux",
  arch: process.arch === "arm64" ? "arm64" : process.arch === "x64" ? "amd64" : process.arch,
});
export const listDir = dir => () => { try { return readdirSync(dir); } catch { return []; } };

// gvproxy processes holding `port` whose spawning bsdkrun (the pid in their
// socket directory) is gone: bsdkrun does not reap them when a machine stops
// or exits, and the stale forward then blocks the next boot. Returns the pids
// killed.
export const reapOrphanGvproxies = port => () => {
  const run = (cmd, args) => { try { return execFileSync(cmd, args, { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] }); } catch { return ""; } };
  const alive = pid => { try { process.kill(pid, 0); return true; } catch (e) { return e.code !== "ESRCH"; } };
  const killed = [];
  for (const pid of run("lsof", ["-nP", `-iTCP:${port}`, "-sTCP:LISTEN", "-t"]).split(/\s+/).filter(Boolean)) {
    const m = /gvproxy.*bsdkrun-net-(\d+)/.exec(run("ps", ["-o", "command=", "-p", pid]));
    if (!m || alive(Number(m[1]))) continue;
    try { process.kill(Number(pid)); killed.push(Number(pid)); } catch {}
  }
  return killed;
};

// Colour only on a terminal, and not when NO_COLOR asks for plain output.
export const colorOutput = () => Boolean(process.stdout.isTTY) && !process.env.NO_COLOR;
export const ansi = code => text => `\x1b[${code}m${text}\x1b[0m`;
