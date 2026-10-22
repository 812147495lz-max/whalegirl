import datetime as dt
import importlib.util
import json
import unittest
import uuid
from pathlib import Path

BRIDGE_PATH = Path(__file__).parents[2] / "Integrations/WhaleGirlCodex/hooks/whalegirl_hook_bridge.py"
SPEC = importlib.util.spec_from_file_location("whalegirl_hook_bridge", BRIDGE_PATH)
BRIDGE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(BRIDGE)


class CodexHookBridgeTests(unittest.TestCase):
    def test_permission_request_is_projected_without_sensitive_fields(self):
        native = {
            "hook_event_name": "PermissionRequest",
            "session_id": "thr_123",
            "turn_id": "turn_456",
            "cwd": "/Users/person/Secret Project",
            "transcript_path": "/private/transcript.jsonl",
            "tool_name": "Bash",
            "tool_input": {"command": "cat $SUPER_SECRET", "description": "secret approval"},
            "prompt": "private prompt",
            "last_assistant_message": "private answer",
        }
        event = BRIDGE.project(
            native,
            dt.datetime(2026, 10, 13, 12, 0, tzinfo=dt.timezone.utc),
            uuid.UUID("00000000-0000-0000-0000-000000000001"),
        )
        self.assertEqual(event["eventType"], "agent.waiting_approval")
        self.assertEqual(event["projectKey"], "SecretProject")
        self.assertEqual(event["metadata"]["approvalKind"], "Bash")
        encoded = json.dumps(event)
        for secret in ["/Users/person", "transcript", "SUPER_SECRET", "private prompt", "private answer"]:
            self.assertNotIn(secret, encoded)

    def test_stop_is_turn_completion_not_session_completion(self):
        event = BRIDGE.project({"hook_event_name": "Stop", "session_id": "thr_1", "cwd": "/tmp/demo"})
        self.assertEqual(event["eventType"], "agent.turn_completed")

    def test_subagent_ids_parent_and_sensitive_fields(self):
        native = dict(hook_event_name="SubagentStart", session_id="parent", agent_id="child", prompt="SECRET", last_assistant_message="SECRET")
        event = BRIDGE.project(native)
        self.assertEqual(event["sessionId"], "child")
        self.assertEqual(event["parentSessionId"], "parent")
        self.assertEqual(event["eventType"], "agent.session_started")
        self.assertNotIn("SECRET", json.dumps(event))
        native["hook_event_name"] = "SubagentStop"
        self.assertEqual(BRIDGE.project(native)["eventType"], "agent.session_completed")
        del native["agent_id"]
        self.assertIsNone(BRIDGE.project(native))

    def test_unknown_hook_is_ignored(self):
        self.assertIsNone(BRIDGE.project({"hook_event_name": "Unknown"}))


if __name__ == "__main__":
    unittest.main()
