#!/usr/bin/env python3
"""Project Codex Hook input to the minimal WhaleEvent v1 contract."""

import datetime as dt
import json
import socket
import sys
import uuid
from pathlib import Path
from typing import Optional

MAX_NATIVE_BYTES = 1024 * 1024
SOCKET_PATH = Path.home() / "Library/Application Support/WhaleGirl/ipc/whalegirl-events.sock"

EVENT_TYPES = {
    "SubagentStart": ("agent.session_started", "info", "子 Agent 已开始"),
    "SubagentStop": ("agent.session_completed", "success", "子 Agent 已完成"),
    "SessionStart": ("agent.session_started", "info", "Codex 会话已开始"),
    "UserPromptSubmit": ("agent.working", "info", "Codex 正在工作"),
    "PreToolUse": ("agent.tool_started", "info", "Codex 正在使用工具"),
    "PermissionRequest": ("agent.waiting_approval", "action_required", "Codex 正在等待操作授权"),
    "PostToolUse": ("agent.tool_finished", "info", "Codex 工具调用已结束"),
    "Stop": ("agent.turn_completed", "success", "Codex 完成一轮回复"),
    "Interrupt": ("agent.interrupted", "warning", "Codex 已中断"),
    "SessionEnd": ("agent.session_completed", "success", "Codex 会话已结束"),
}


def identifier(value: object, fallback: str, maximum: int = 128) -> str:
    text = str(value or fallback)
    return "".join(ch for ch in text if ch.isalnum() or ch in "-_.")[:maximum] or fallback


def send(event: dict) -> None:
    frame = json.dumps(event, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
    if len(frame) > 16 * 1024:
        return
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(0.2)
        client.connect(str(SOCKET_PATH))
        client.sendall(frame)


def project(native: dict, now: Optional[dt.datetime] = None, event_id: Optional[uuid.UUID] = None) -> Optional[dict]:
    hook_name = native.get("hook_event_name")
    mapping = EVENT_TYPES.get(hook_name)
    if mapping is None:
        return None
    event_type, severity, summary = mapping
    parent_id = None
    session_id = identifier(native.get("session_id"), "unknown-session", 256)
    if hook_name in ("SubagentStart", "SubagentStop"):
        if not native.get("agent_id") or not native.get("session_id"):
            return None
        parent_id = session_id
        session_id = identifier(native["agent_id"], "", 256)
        if not session_id or session_id == parent_id:
            return None
    cwd = native.get("cwd")
    project_alias = identifier(Path(cwd).name if isinstance(cwd, str) else None, "Codex", 160)
    metadata = {"client": "codex-hook"}
    if hook_name == "PermissionRequest":
        metadata["approvalKind"] = identifier(native.get("tool_name"), "tool", 128)
    timestamp = (now or dt.datetime.now(dt.timezone.utc)).astimezone(dt.timezone.utc).replace(microsecond=0)
    return {
            "schemaVersion": 1,
            "eventId": str(event_id or uuid.uuid4()),
            "source": "codex",
            "sourceInstance": "codex-hooks",
            "sessionId": session_id,
            "parentSessionId": parent_id,
            "projectKey": project_alias,
            "eventType": event_type,
            "occurredAt": timestamp.isoformat().replace("+00:00", "Z"),
            "receivedAt": None,
            "sequence": None,
            "severity": severity,
            "summary": summary,
            "displayTarget": {"kind": "none", "bundleId": None, "uri": None},
            "metadata": metadata,
            "privacyClass": "metadata_only",
        }


def main() -> int:
    raw = sys.stdin.buffer.read(MAX_NATIVE_BYTES + 1)
    try:
        if len(raw) > MAX_NATIVE_BYTES:
            return 0
        native = json.loads(raw)
        event = project(native)
        if event is not None:
            send(event)
    except (OSError, ValueError, TypeError):
        pass
    finally:
        # Neutral valid output for hooks such as Stop; this never changes a Codex decision.
        sys.stdout.write("{}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
