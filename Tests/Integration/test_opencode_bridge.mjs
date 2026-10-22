import assert from 'node:assert/strict';
import net from 'node:net';
import {mkdtemp,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {WhaleGirlReplies} from '../../Apps/macOS/Resources/AIMonitor/ReplyHooks/whalegirl-opencode.mjs';
const folder=await mkdtemp(join(tmpdir(),'whale-opencode-')), path=join(folder,'events.sock'), events=[];
const server=net.createServer(socket=>{let text='';socket.on('data',chunk=>text+=chunk);socket.on('end',()=>{for(const line of text.trim().split('\n'))if(line)events.push(JSON.parse(line));});});
await new Promise(resolve=>server.listen(path,resolve));
try {
 const client={session:{get:async({path:{id}})=>id==='unknown'?{error:'not found'}:{data:{id,parentID:id==='child'?'root':undefined,title:'PRIVATE',directory:'/private/path'}}}};
 const observer=await WhaleGirlReplies({client,whaleTestSocket:path});
 const event=async(type,id,status)=>observer.event({event:{type,properties:{sessionID:id,status:{type:status},prompt:'SECRET',error:'PRIVATE'}}});
 await event('session.status','root','busy');await event('session.status','root','busy');
 await event('session.status','root','idle');await event('session.idle','root');
 assert.equal(events.filter(x=>x.eventType==='agent.working').length,1);
 assert.equal(events.filter(x=>x.eventType==='agent.turn_completed').length,1);
 await event('session.status','child','busy');await event('session.idle','child');
 assert.equal(events.at(-1).parentSessionId,'root');assert.equal(events.at(-1).eventType,'agent.session_completed');
 await event('session.status','root','busy');await event('session.error','root');await event('session.idle','root');
 assert.equal(events.at(-1).eventType,'agent.failed');
 const count=events.length;await event('session.status','unknown','busy');await event('session.idle','unknown');assert.equal(events.length,count);
 await Promise.all([event('session.status','parallel','busy'),event('session.status','parallel','idle')]);
 assert.deepEqual(events.filter(x=>x.sessionId==='parallel').map(x=>x.eventType),['agent.working','agent.turn_completed']);
 const raw=JSON.stringify(events);assert.ok(!raw.includes('SECRET')&&!raw.includes('PRIVATE')&&!raw.includes('/private/path'));
 assert.equal(new Set(events.map(x=>x.sequence)).size,events.length);
 console.log('OpenCode official plugin projection: root/child, duplicate, failure, unknown ownership and privacy passed');
} finally {await new Promise(resolve=>server.close(resolve));await rm(folder,{recursive:true,force:true});}
