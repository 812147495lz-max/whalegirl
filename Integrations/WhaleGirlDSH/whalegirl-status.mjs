/** Read-only DeepSeek Harness child-agent observer. Only public task labels and lifecycle metadata; no prompts, tools or model output. */
import net from 'node:net';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';
import { writeFileSync, renameSync } from 'node:fs';
export const name = 'whalegirl-dsh-status';
export const inject = ['agents'];
const clean = value => String(value ?? '').replace(/[^a-zA-Z0-9_.-]/g, '').slice(0, 128);

export function apply(ctx, config = {}) {
  const socketPath = config.socketPath ?? join(homedir(), 'Library/Application Support/WhaleGirl/ipc/whalegirl-events.sock');
  const children = new Map();
  const roots = new Map();
  const completedRootTurns = new Map();
  const rootTurnsWithSteps = new Map();
  let sequence = Date.now() * 1000;
  let healthTime = 0, healthCount = -1;
  function health() {
    if (config.socketPath) return; // Isolated tests never write to the user's real profile.
    const active = [...children.values()].filter(entry => entry.running && !entry.finished).length;
    if (active === healthCount && Date.now() - healthTime < (active ? 10000 : 60000)) return;
    healthTime = Date.now(); healthCount = active;
    const path = join(homedir(), 'Library/Application Support/WhaleGirl/integrations/dsh-observer-health.json');
    try {
      writeFileSync(path + '.tmp', JSON.stringify({ version: 5, pid: process.pid, activeChildren: active, updatedAt: new Date().toISOString() }), { mode: 0o600 });
      renameSync(path + '.tmp', path);
    } catch {} // Diagnostic metadata must never disturb DSH.
  }
  function parentOf(agent) {
    const agents = ctx.agents?.list?.() ?? [];
    const owner = agents.find(candidate => candidate !== agent && ctx.agents.isOwnedBy?.(agent.id, candidate));
    if (owner) return clean(owner.id);
    // Root/resumed/forked sessions are not active delegated children.
    if (ctx.agents.roots?.().some(root => root.id === agent.id)) return null;
    const header = agent.session?.header;
    return header?.origin === 'subagent' && header.parentSession ? clean(header.parentSession) : null;
  }
  let pending = [];
  let flushing = false, retry;
  function flush() {
    if (flushing || pending.length === 0) return;
    flushing = true;
    const batch = pending.splice(0, 64);
    const socket = net.createConnection({ path: socketPath }); socket.unref(); socket.setTimeout(1000);
    let delivered = false;
    socket.on('connect', () => socket.end(batch.map(item => item.frame).join('')));
    socket.on('finish', () => { delivered = true; });
    socket.on('error', () => socket.destroy()); socket.on('timeout', () => socket.destroy());
    socket.on('close', () => {
      flushing = false;
      if (!delivered) pending.unshift(...batch.filter(item => Date.now() - item.at < 60000));
      if (pending.length > 1024) pending.splice(0, pending.length - 1024);
      retry = setTimeout(flush, delivered ? 0 : 300); retry.unref();
    });
  }
  function publicLabel(id) {
    try {
      const agent = ctx.agents.get?.(id);
      const service = ctx.get?.('sessionProjections');
      const identity = agent?.session && service?.snapshot(agent.session, ['subagent'])?.values?.subagent;
      if (!identity || !agent.session.isOwnSeq?.(identity.seq) || typeof identity.label !== 'string') return;
      const label = identity.label.replace(/[\p{Cc}\p{Cf}]/gu, ' ').replace(/\s+/g, ' ').trim();
      if (!label || /[\\/@]|bearer|password|secret|sk-[a-z0-9]|api[_-]?key/i.test(label)) return;
      return Array.from(label).slice(0, 40).join('');
    } catch {} // Labels are optional; observer availability must never depend on this service.
  }
  function send(entry, eventType) {
    const agentLabel = entry.parent ? publicLabel(entry.id) : undefined;
    const event = { schemaVersion: 1, eventId: randomUUID(), source: 'dsh', sourceInstance: `dsh-${process.pid}`,
      sessionId: entry.id, parentSessionId: entry.parent, eventType,
      occurredAt: new Date().toISOString().replace(/\.\d{3}Z$/, 'Z'), sequence: ++sequence,
      severity: eventType === 'agent.turn_completed' ? 'success' : 'info',
      metadata: { client: 'dsh-whale-status', ...(agentLabel ? { agentLabel } : {}) }, privacyClass: 'metadata_only' };
    if (eventType === 'agent.heartbeat') {
      const index = pending.findIndex(item => item.id === entry.id && item.type === eventType);
      if (index >= 0) pending.splice(index, 1);
    }
    pending.push({ id: entry.id, type: eventType, at: Date.now(), frame: JSON.stringify(event) + '\n' });
    flush();
  }
  function created(agent, existing = false) {
    const parent = parentOf(agent), id = clean(agent.id);
    if (!parent || !id || id === parent || (existing && agent.status !== 'running')) return;
    if (children.has(id)) return;
    const entry = { id, parent, running: agent.status === 'running', finished: false };
    children.set(id, entry); send(entry, 'agent.session_started');
  }
  ctx.on('agent/created', ({ agent }) => { created(agent); });
  ctx.on('session/event', (session, event) => {
    // Read event kind/turn/reason only; never inspect messages, errors or reply content.
    if (!['step/start', 'turn/end'].includes(event?.type)) return;
    const agent = ctx.agents.get?.(session.id);
    if (!agent || parentOf(agent)) return;
    const id = clean(agent.id), turn = event.data?.turn;
    if (!id || !Number.isInteger(turn)) return;
    if (event.type === 'step/start') {
      if (rootTurnsWithSteps.get(id) !== turn) send({ id }, 'agent.working');
      roots.set(id, true); rootTurnsWithSteps.set(id, turn); return;
    }
    const hadStep = rootTurnsWithSteps.get(id) === turn;
    if (hadStep) rootTurnsWithSteps.delete(id);
    if (!hadStep || completedRootTurns.get(id) === turn) return;
    roots.set(id, false);
    if (event.data?.reason?.kind !== 'completed') { send({ id }, 'agent.interrupted'); return; }
    completedRootTurns.set(id, turn);
    send({ id }, 'agent.turn_completed');
  });
  ctx.on('agent/status', ({ agent, status }) => {
    if (status === 'running' && !parentOf(agent)) { roots.set(clean(agent.id), true); send({ id: clean(agent.id) }, 'agent.working'); }
    if (!children.has(clean(agent.id)) && status === 'running') created(agent);
    const entry = children.get(clean(agent.id)); if (!entry) return;
    if (status === 'running') {
      entry.running = true; entry.finished = false; send(entry, 'agent.working');
    } else if (entry.running && !entry.finished) {
      entry.running = false; entry.finished = true; send(entry, 'agent.session_completed');
    }
  });
  ctx.on('agent/disposed', ({ agent }) => {
    const rootId = clean(agent.id);
    if (roots.get(rootId)) send({ id: rootId }, 'agent.disconnected');
    roots.delete(rootId); completedRootTurns.delete(rootId); rootTurnsWithSteps.delete(rootId);
    const entry = children.get(clean(agent.id)); if (!entry) return;
    if (!entry.finished) send(entry, 'agent.disconnected');
    children.delete(entry.id);
  });
  // Reconcile actual runtime metadata, including children already running before the observer/app.
  function reconcile() {
    const live = new Map((ctx.agents?.list?.() ?? []).map(agent => [clean(agent.id), agent]));
    for (const [id, entry] of children) {
      const agent = live.get(id);
      if (entry.running && !entry.finished && (!agent || agent.status !== 'running')) {
        entry.running = false; entry.finished = true;
        send(entry, agent ? 'agent.session_completed' : 'agent.disconnected');
      }
      if (!agent) children.delete(id);
    }
    for (const [id, active] of roots) {
      if (active && live.get(id)?.status !== 'running') { roots.set(id, false); send({ id }, 'agent.interrupted'); }
      if (!live.has(id)) roots.delete(id);
    }
    for (const agent of live.values()) {
      if (agent.status === 'running' && !parentOf(agent)) {
        const id = clean(agent.id);
        if (!roots.has(id)) { roots.set(id, true); send({ id }, 'agent.working'); }
        else if (roots.get(id)) send({ id }, 'agent.heartbeat');
        continue;
      }
      if (agent.status !== 'running') continue;
      if (!children.has(clean(agent.id))) created(agent, true);
      const entry = children.get(clean(agent.id));
      if (!entry) continue;
      if (!entry.running || entry.finished) {
        entry.running = true; entry.finished = false; send(entry, 'agent.working');
      } else { send(entry, 'agent.heartbeat'); }
    }
    health();
  }
  queueMicrotask(reconcile);
  const heartbeat = setInterval(reconcile, 2000); heartbeat.unref();
  ctx.on('dispose', () => {
    clearInterval(heartbeat); clearTimeout(retry);
    for (const entry of children.values()) if (entry.running && !entry.finished) send(entry, 'agent.disconnected');
    for (const [id, active] of roots) if (active) send({ id }, 'agent.disconnected');
    roots.clear(); children.clear();
  });
}
