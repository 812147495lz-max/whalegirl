import importlib.util
import json
import unittest
from pathlib import Path
from unittest import mock
path=Path(__file__).parents[2]/'Apps/macOS/Resources/AIMonitor/ReplyHooks/whale_reply_hook.py'
spec=importlib.util.spec_from_file_location('reply_hook',path);hook=importlib.util.module_from_spec(spec);spec.loader.exec_module(hook)
class ReplyHookTests(unittest.TestCase):
    def test_native_ids_and_sensitive_fields(self):
        for provider,payload in [('gemini',dict(session_id='g')),('grok',dict(sessionId='x',reason='end_turn')),('cursor',dict(conversation_id='c',generation_id='t',status='completed')),('copilot',dict(sessionId='p',stopReason='end_turn')),('claude',dict(session_id='a'))]:
            payload.update(prompt='SECRET',last_assistant_message='SECRET',user_email='PRIVATE',transcript_path='/private/transcript')
            value=hook.project(provider,'completed',payload)
            self.assertEqual(value['eventType'],'agent.turn_completed');self.assertEqual(value['metadata']['provider'],provider)
            raw=json.dumps(value)
            for secret in ['SECRET','PRIVATE','transcript','/private']:self.assertNotIn(secret,raw)
    def test_failed_cancelled_and_missing_identity_are_not_success(self):
        for provider,payload in [('cursor',dict(session_id='s',status='aborted')),('cursor',dict(session_id='s',status='error')),('grok',dict(sessionId='s',reason='shutdown')),('gemini',{}),('copilot',dict(sessionId='p',stopReason='cancelled')),('gemini',dict(session_id='g',error='PRIVATE'))]:
            self.assertIsNone(hook.project(provider,'completed',payload))
    def test_grok_compatibility_preserves_real_provider(self):
        with mock.patch.dict(hook.os.environ,{'GROK_HOOK_EVENT':'stop'}):
            self.assertEqual(hook.project('cursor','completed',dict(sessionId='s',reason='end_turn'))['metadata']['provider'],'grok-cli')
    def test_child_identity_is_required_and_payload_is_not_forwarded(self):
        for provider,payload in [('claude',dict(session_id='parent',agent_id='child')),('cursor',dict(parent_conversation_id='parent',subagent_id='child')),('copilot',dict(sessionId='parent',agentId='child'))]:
            payload.update(prompt='SECRET',task='SECRET',last_assistant_message='PRIVATE')
            value=hook.project(provider,'child-start',payload)
            self.assertEqual(value['parentSessionId'],'parent');self.assertEqual(value['sessionId'],'child')
            self.assertEqual(value['eventType'],'agent.session_started');self.assertNotIn('SECRET',str(value));self.assertNotIn('PRIVATE',str(value))
        self.assertIsNone(hook.project('copilot','child-start',dict(sessionId='parent',agentName='not-a-unique-id')))
        value=hook.project('cursor','child-end',dict(parent_conversation_id='parent',subagent_id='child',status='error'))
        self.assertEqual(value['eventType'],'agent.failed')
if __name__=='__main__':unittest.main()
