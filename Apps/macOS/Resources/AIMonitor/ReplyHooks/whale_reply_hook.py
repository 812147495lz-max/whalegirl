#!/usr/bin/env python3
"""Project native reply hooks to local metadata only; never forward response/prompt text."""
import argparse
import datetime as dt
import json
import os
import re
import socket
import sys
import uuid
import time
from pathlib import Path


def project(provider, stage, native):
    # Grok imports Cursor/Claude compatibility hooks; preserve the real producer name.
    if os.environ.get('GROK_HOOK_EVENT'): provider = 'grok-cli'
    if not re.fullmatch(r'[a-z0-9][a-z0-9_.-]{0,39}', provider): return None
    if stage not in ['working', 'completed', 'child-start', 'child-end']: return None
    if stage in ['child-start','child-end']:
        # Only explicit identities from official events; never invent an ID from a task name.
        parent=native.get('parent_conversation_id') or native.get('session_id') or native.get('sessionId') or native.get('conversation_id')
        child=native.get('agent_id') or native.get('agentId') or native.get('subagent_id')
        if not all(isinstance(x,str) and x for x in [parent,child]):return None
        parent=re.sub(r'[^A-Za-z0-9_.-]','',parent)[:256];child=re.sub(r'[^A-Za-z0-9_.-]','',child)[:256]
        if not parent or not child or parent==child:return None
        event_type='agent.session_started' if stage=='child-start' else 'agent.session_completed'
        if stage=='child-end' and native.get('status') in ['error','aborted','cancelled']:event_type='agent.failed'
        return dict(schemaVersion=1,eventId=str(uuid.uuid4()),source='remote',sourceInstance=provider+'-reply-hooks',
            sessionId=child,parentSessionId=parent,eventType=event_type,sequence=time.time_ns()//1000,
            occurredAt=dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00','Z'),
            severity='info',metadata=dict(client='whale-reply-hook',provider=provider),privacyClass='metadata_only')
    if stage == 'completed':
        if provider == 'cursor' and native.get('status') != 'completed': return None
        if provider in ['grok', 'grok-cli'] and native.get('reason') not in [None, 'end_turn']: return None
        if provider == 'copilot' and native.get('stopReason', native.get('stop_reason')) != 'end_turn': return None
        if native.get('error') is not None: return None
        if native.get('status') in ['error', 'aborted', 'cancelled']: return None
        if native.get('parent_session_id') or native.get('parentSessionId'): return None
    session = native.get('session_id') or native.get('sessionId') or native.get('conversation_id')
    if not isinstance(session, str) or not session: return None
    turn = native.get('generation_id') or native.get('promptId')
    if isinstance(turn, str) and turn: session += '.' + turn
    session = re.sub(r'[^A-Za-z0-9_.-]', '', session)[:256]
    if not session: return None
    return dict(schemaVersion=1, eventId=str(uuid.uuid4()), source='remote', sourceInstance=provider+'-reply-hooks',
        sessionId=session, eventType='agent.turn_completed' if stage=='completed' else 'agent.working',
        occurredAt=dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace('+00:00','Z'),
        sequence=time.time_ns()//1000, severity='success' if stage=='completed' else 'info', metadata=dict(client='whale-reply-hook', provider=provider),
        privacyClass='metadata_only')


def main():
    parser=argparse.ArgumentParser();parser.add_argument('--provider', required=True);parser.add_argument('--event', required=True)
    args=parser.parse_args()
    try:
        raw=sys.stdin.buffer.read(1048577)
        if len(raw)>1048576: return
        native=json.loads(raw)
        if not isinstance(native,dict): return
        event=project(args.provider,args.event,native)
        if event is None: return
        path=Path.home()/'Library/Application Support/WhaleGirl/ipc/whalegirl-events.sock'
        with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as client:
            client.settimeout(0.2);client.connect(str(path));client.sendall((json.dumps(event)+'\n').encode())
    except (OSError,ValueError,TypeError): pass
    finally:
        print('{}') # Neutral output: never blocks or continues the model.

if __name__=='__main__': main()
