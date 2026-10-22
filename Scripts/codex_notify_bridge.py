#!/usr/bin/env python3
"""Privacy-filtered bridge for Codex's agent-turn-complete notify payload."""

import datetime as dt
import json
import socket
import sys
import uuid
from pathlib import Path

SOCKET_PATH = Path.home() / "Library/Application Support/WhaleGirl/ipc/whalegirl-events.sock"


def clean_identifier(value: object, fallback: str) -> str:
    text = str(value or fallback)
    return "".join(ch for ch in text if ch.isalnum() or ch in "-_.")[:128] or fallback


def main() -> int:
    try:
        native = json.loads(sys.argv[-1])
        if native.get("type") != "agent-turn-complete":
            return 0
        session_id = clean_identifier(native.get("thread-id"), "unknown-session")
        cwd = native.get("cwd")
        project_alias = clean_identifier(Path(cwd).name if isinstance(cwd, str) else None, "Codex")
        event = {
            "schemaVersion": 1,
            "eventId": str(uuid.uuid4()),
            "source": "codex",
            "sourceInstance": "codex-notify",
            "sessionId": session_id,
            "parentSessionId": None,
            "projectKey": project_alias,
            "eventType": "agent.turn_completed",
            "occurredAt": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
            "receivedAt": None,
            "sequence": None,
            "severity": "success",
            "summary": "Codex 完成一轮回复",
            "displayTarget": {"kind": "app", "bundleId": "com.openai.codex", "uri": None},
            "metadata": {"client": "codex-notify"},
            "privacyClass": "metadata_only",
        }
        frame = json.dumps(event, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(0.2)
            client.connect(str(SOCKET_PATH))
            client.sendall(frame)
        return 0
    except (OSError, ValueError, TypeError):
        # Codex must never fail because its optional desktop notification bridge is unavailable.
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
