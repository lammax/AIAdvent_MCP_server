import { createRequire } from 'node:module';
import { realpathSync } from 'node:fs';
const require = createRequire(process.argv[2] + '/package.json');
const { listSessions, getSessionInfo } = await import(require.resolve('@anthropic-ai/claude-agent-sdk'));
const paths = JSON.parse(process.argv[3]).map(p => realpathSync(p));
const known = new Set(JSON.parse(process.argv[4]));
const sessions = new Map();
for (const dir of paths) {
  for (const s of await listSessions({dir, limit: 100, includeWorktrees: false, includeProgrammatic: true})) sessions.set(s.sessionId, s);
  for (const id of known) {
    const s = await getSessionInfo(id, {dir});
    if (s) sessions.set(s.sessionId, s);
  }
}
const result = [];
for (const s of sessions.values()) {
  if (!s.cwd || ['__hidden', 'archived', 'remote-diagnostic'].includes(s.tag) || s.firstPrompt?.startsWith('[Remote diagnostic]')) continue;
  let cwd;
  try { cwd = realpathSync(s.cwd); } catch { continue; }
  if (!paths.includes(cwd)) continue;
  result.push({id:s.sessionId, title:s.customTitle || s.summary || s.sessionId,
    project:cwd, updatedAt:s.lastModified / 1000, busy:false});
}
process.stdout.write(JSON.stringify(result));
