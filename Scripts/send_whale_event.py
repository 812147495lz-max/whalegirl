#!/usr/bin/env python3
"""Send one already-sanitized WhaleEvent v1 JSON object to WhaleGirl."""

import json
import socket
import sys
from pathlib import Path

MAX_FRAME_BYTES = 16 * 1024
SOCKET_PATH = Path.home() / "Library/Application Support/WhaleGirl/ipc/whalegirl-events.sock"


def main() -> int:
    try:
        payload = json.load(sys.stdin)
        frame = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode("utf-8") + b"\n"
        if len(frame) > MAX_FRAME_BYTES:
            return 2
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(0.25)
            client.connect(str(SOCKET_PATH))
            client.sendall(frame)
        return 0
    except (OSError, ValueError, TypeError):
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
