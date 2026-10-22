import assert from 'node:assert/strict';
import net from 'node:net';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { apply } from '../../Integrations/WhaleGirlDSH/whalegirl-status.mjs';
const folder = await mkdtemp(join(tmpdir(), 'whale-dsh-'));
const socketPath = join(folder, 'events.sock'), events = [], listeners = new Map();
const server = net.createServer(socket => {
 let data = ''; socket.on('data', chunk => data += chunk);
 socket.on('end', () => { for (const line of data.trim().split('\n')) if (line) events.push(JSON.parse(line)); });
});
await new Promise(resolve => server.listen(socketPath, resolve));
const root = { id: 'root', status: 'running', session: { header: {} } };
const child = { id: 'child', status: 'running', session: { isOwnSeq: seq => seq === 7, header: { origin: 'subagent', parentSession: 'root' } } };
const fork = { id: 'fork', status: 'running', session: { header: { parentSession: 'root' } } };
const agents = [root, child, fork];
const ctx = { get: key => key === 'sessionProjections' ? { snapshot: () => ({ values: { subagent: { seq: 7, label: '检查设置页面' } } }) } : undefined, agents: { list: () => agents, get: id => agents.find(agent => agent.id === id), roots: () => [root, fork], isOwnedBy: (id, owner) => id === 'child' && owner === root }, on: (name, fn) => listeners.set(name, fn) };
const pause = () => new Promise(resolve => setTimeout(resolve, 50));
try {
 apply(ctx, { socketPath }); await pause();
 assert.equal(events.filter(event => event.eventType === 'agent.session_started').length, 1); const firstChild = events.find(event => event.sessionId === 'child'); assert.equal(firstChild.parentSessionId, 'root'); assert.equal(firstChild.metadata.agentLabel, '检查设置页面');
 assert.equal(events.filter(event => event.sessionId === 'root' && event.eventType === 'agent.working').length, 1);
 child.status = 'idle'; listeners.get('agent/status')({ agent: child, status: 'idle' }); await pause();
 assert.equal(events.at(-1).eventType, 'agent.session_completed'); assert.equal(events.at(-1).severity, 'info');
 const count = events.length;
 agents.splice(agents.indexOf(child), 1); listeners.get('agent/disposed')({ agent: child }); await pause(); assert.equal(events.length, count);
 child.status = 'running'; agents.push(child); listeners.get('agent/status')({ agent: child, status: 'running' }); await pause();
 agents.splice(agents.indexOf(child), 1); listeners.get('agent/disposed')({ agent: child }); await pause();
 assert.equal(events.at(-1).eventType, 'agent.disconnected');
 for (const event of events) { assert.equal(event.privacyClass, 'metadata_only'); assert.ok(!('prompt' in event)); }
 // Root completion requires a real step and a successful terminal reason.
 const rootEnd = (turn, kind) => listeners.get('session/event')({ id: 'root' }, { type: 'turn/end', data: { turn, reason: { kind } } });
 const rootStep = turn => listeners.get('session/event')({ id: 'root' }, { type: 'step/start', data: { turn, step: 1 } });
 rootEnd(0, 'completed'); rootStep(1); rootEnd(1, 'completed'); rootEnd(1, 'completed');
 rootStep(2); rootEnd(2, 'aborted'); rootStep(3); rootEnd(3, 'error');
 listeners.get('session/event')({ id: 'burst-unknown' }, { type: 'turn/end', data: { turn: 4, reason: { kind: 'completed' } } });
 await pause();
 assert.ok(events.filter(event => event.sessionId === 'root' && event.eventType === 'agent.working').length >= 4, 'same main agent rearms for later turns');
 const replies = events.filter(event => event.eventType === 'agent.turn_completed');
 assert.equal(replies.length, 1); assert.equal(replies[0].sessionId, 'root'); assert.equal(replies[0].parentSessionId, undefined);
 // A burst larger than the native listen backlog must be batched, not dropped.
 for (let index = 0; index < 40; index++) {
   const agent = { id: `burst-${index}`, status: 'running', session: { header: { origin: 'subagent', parentSession: 'root' } } };
   agents.push(agent); listeners.get('agent/created')({ agent });
 }
 await new Promise(resolve => setTimeout(resolve, 250));
 assert.equal(new Set(events.filter(event => event.eventType === 'agent.session_started' && event.sessionId.startsWith('burst-')).map(event => event.sessionId)).size, 40);
 // Simulate WhaleGirl being restarted: temporarily absent socket, no model execution.
 await new Promise(resolve => server.close(resolve));
 const late = { id: 'late', status: 'running', session: { header: { origin: 'subagent', parentSession: 'root' } } };
 agents.push(late); listeners.get('agent/created')({ agent: late }); await pause();
 await new Promise(resolve => server.listen(socketPath, 8, resolve));
 await new Promise(resolve => setTimeout(resolve, 650));
 assert.equal(events.filter(event => event.sessionId === 'late' && event.eventType === 'agent.session_started').length, 1);
 // Main-agent heartbeats must keep actual work alive without reviving completed turns.
 const rootWorkCount = events.filter(event => event.sessionId === 'root' && event.eventType === 'agent.working').length;
 // Reconcile must repair missed idle and disposal notifications.
 agents.find(agent => agent.id === 'burst-0').status = 'idle';
 agents.splice(agents.findIndex(agent => agent.id === 'burst-1'), 1);
 await new Promise(resolve => setTimeout(resolve, 2200));
 assert.equal(events.filter(event => event.sessionId === 'burst-0' && event.eventType === 'agent.session_completed').length, 1);
 assert.equal(events.filter(event => event.sessionId === 'burst-1' && event.eventType === 'agent.disconnected').length, 1);
 assert.equal(events.filter(event => event.sessionId === 'root' && event.eventType === 'agent.working').length, rootWorkCount);
 assert.ok(events.some(event => event.sessionId === 'fork' && event.eventType === 'agent.heartbeat'));
 console.log('DSH bridge burst, reconnect and missed-status lifecycle fixture passed');
} finally {
 listeners.get('dispose')?.(); await new Promise(resolve => server.close(resolve)); await rm(folder, { recursive: true });
}
