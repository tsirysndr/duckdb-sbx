import { appendFileSync } from 'node:fs';
import { randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';

// Parse the typed result, never arbitrary log lines. Setup logs can precede it.
export function setupEnvironment(output) {
  const lines = output.trimEnd().split('\n');
  for (let start = lines.length - 1; start >= 0; start--) {
    let result;
    try { result = JSON.parse(lines.slice(start).join('\n')); } catch { continue; }
    if (!Array.isArray(result?.environment) || result.environment.length === 0) continue;
    for (const item of result.environment) {
      if (!item || typeof item.name !== 'string' || !/^[A-Za-z_][A-Za-z0-9_]*$/.test(item.name) || typeof item.value !== 'string' || item.value.includes('\0')) {
        throw Error('Invalid setup environment entry');
      }
    }
    return result.environment;
  }
  throw Error('setup-purescript did not return a typed environment result');
}

export function persistEnvironment(output, destination) {
  const entries = setupEnvironment(output);
  const marker = `fluentci_${randomUUID()}`;
  appendFileSync(destination, entries.map(({ name, value }) => `${name}<<${marker}\n${value}\n${marker}\n`).join(''));
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  let output = '';
  for await (const chunk of process.stdin) { process.stdout.write(chunk); output += chunk; }
  if (!process.env.GITHUB_ENV) throw Error('GITHUB_ENV is required');
  persistEnvironment(output, process.env.GITHUB_ENV);
}
