import net from 'node:net';
import { homedir } from 'node:os';
import { join } from 'node:path';
import { randomUUID } from 'node:crypto';

// OpenCode's documented plugin events and injected SDK; never access messages or part contents.
export const WhaleGirlReplies = async (input = {}) => {
 const parents = new Map(), busySessions = new Set(), failedSessions = new Set();
 const socketPath = input.whaleTestSocket ?? join(homedir(),'Library/Application Support/WhaleGirl/ipc/whalegirl-events.sock');
 let sequence = Date.now() * 1000;
 const safeID = value => typeof value === 'string' && /^[A-Za-z0-9_.-]{1,256}$/.test(value) ? value : null;
 async function parentFor(id) {
   if (parents.has(id)) return parents.get(id);
   // Sessions already open before plugin load have no created event. Resolve metadata through the official SDK.
   try {
     const result = await Promise.race([
       input.client?.session?.get({path:{id}}),
       new Promise(resolve => { const timer = setTimeout(() => resolve(null), 800); timer.unref?.(); })
     ]);
     const info = result?.data;
     if (info?.id !== id || (info.parentID != null && !safeID(info.parentID))) return undefined;
     const parent = info.parentID ?? null; parents.set(id, parent); return parent;
   } catch { return undefined; }
 }
 function send(id, parent, type) {
   const frame = { schemaVersion:1, eventId:randomUUID(), source:'remote', sourceInstance:'opencode-reply-hooks',
     sessionId:id, ...(parent ? {parentSessionId:parent} : {}), eventType:type, sequence:++sequence,
     occurredAt:new Date().toISOString().replace(/\.\d{3}Z$/,'Z'),
     severity:type==='agent.turn_completed'?'success':type==='agent.failed'?'error':'info',
     metadata:{client:'whale-reply-hook',provider:'opencode'}, privacyClass:'metadata_only' };
   return new Promise(resolve => {
     const socket=net.createConnection({path:socketPath});socket.unref();socket.setTimeout(200);
     socket.on('error',()=>socket.destroy());socket.on('timeout',()=>socket.destroy());socket.on('close',resolve);
     socket.on('connect',()=>socket.end(JSON.stringify(frame)+'\n'));
   });
 }
 let chain = Promise.resolve();
 async function handle(event) {
   if (event.type==='session.created' || event.type==='session.updated') {
     const info=event.properties?.info, id=safeID(info?.id);
     if (id && (info.parentID==null || safeID(info.parentID))) parents.set(id,info.parentID??null);
     if (parents.size>2048) parents.delete(parents.keys().next().value);
     return;
   }
   if (event.type==='session.deleted') {
     const id=event.properties?.info?.id;
     if (busySessions.delete(id)) { const parent=parents.get(id); if (parent!==undefined) await send(id,parent,'agent.disconnected'); }
     parents.delete(id); failedSessions.delete(id); return;
   }
   const id=safeID(event.properties?.sessionID);
   if (!id) return;
   const error=event.type==='session.error';
   const idle=event.type==='session.idle' || (event.type==='session.status' && event.properties?.status?.type==='idle');
   const busy=event.type==='session.status' && event.properties?.status?.type==='busy';
   if (!error && !idle && !busy) return;
   const parent=await parentFor(id);
   if (parent===undefined) return; // Unknown ownership must not masquerade as a successful root reply.
   if (error) {
     failedSessions.add(id);
     if (busySessions.delete(id)) await send(id,parent,'agent.failed');
     return;
   }
   if (busy) {
     if (busySessions.has(id)) return;
     busySessions.add(id);failedSessions.delete(id);
     await send(id,parent,'agent.working');return;
   }
   if (!busySessions.delete(id)) return;
   if (failedSessions.delete(id)) return;
   await send(id,parent,parent?'agent.session_completed':'agent.turn_completed');
 }
 return {event: ({event}) => {
   if (!['session.created','session.updated','session.deleted','session.error','session.idle','session.status'].includes(event?.type)) return Promise.resolve();
   // Keep event order while resolving pre-existing session metadata asynchronously.
   const job = chain.then(() => handle(event)); chain = job.catch(() => {}); return chain;
 }};
};
