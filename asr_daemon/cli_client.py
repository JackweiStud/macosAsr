"""CLI test client for asr_daemon IPC (SDD §10.3)."""

from __future__ import annotations

import argparse
import json
import socket
import sys
import time
from pathlib import Path

from asr.run_utils import PROJECT_ROOT

DEFAULT_SOCKET = PROJECT_ROOT / "run" / "macosasr.sock"


def _read_events(sock: socket.socket, buffer: str, timeout: float) -> tuple[list[dict], str]:
    events: list[dict] = []
    sock.settimeout(timeout)
    try:
        while True:
            chunk = sock.recv(4096)
            if not chunk:
                break
            buffer += chunk.decode("utf-8")
            while "\n" in buffer:
                part, buffer = buffer.split("\n", 1)
                part = part.strip()
                if part:
                    events.append(json.loads(part))
    except socket.timeout:
        pass
    return events, buffer


def send_command(socket_path: Path, cmd: dict, *, timeout: float = 3.0) -> list[dict]:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(str(socket_path))
    line = json.dumps(cmd, ensure_ascii=False) + "\n"
    sock.sendall(line.encode("utf-8"))
    events, _ = _read_events(sock, "", timeout)
    sock.close()
    return events


def cmd_ping(socket_path: Path) -> int:
    events = send_command(socket_path, {"protocol": 1, "cmd": "ping"})
    for ev in events:
        print(json.dumps(ev, ensure_ascii=False, indent=2))
    if not events:
        print("no response", file=sys.stderr)
        return 1
    return 0 if events[0].get("type") == "pong" else 1


def cmd_session_test(socket_path: Path, duration: float) -> int:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(str(socket_path))
    all_events: list[dict] = []

    def send(cmd: dict) -> None:
        sock.sendall((json.dumps(cmd, ensure_ascii=False) + "\n").encode("utf-8"))

    send({"protocol": 1, "cmd": "session_start", "language": "Chinese"})
    buffer = ""
    deadline = time.time() + duration
    while time.time() < deadline:
        evs, buffer = _read_events(sock, buffer, 0.3)
        all_events.extend(evs)

    send({"protocol": 1, "cmd": "session_stop"})
    deadline = time.time() + 5.0
    while time.time() < deadline:
        evs, buffer = _read_events(sock, buffer, 0.3)
        all_events.extend(evs)
        if any(e.get("type") in ("final", "filtered", "session_stopped") for e in evs):
            break

    sock.close()

    for ev in all_events:
        print(json.dumps(ev, ensure_ascii=False))

    partials = [e for e in all_events if e.get("type") == "partial"]
    finals = [e for e in all_events if e.get("type") in ("final", "filtered")]
    t02 = len(partials) >= 1
    t03 = len(finals) >= 1
    print(
        f"\n--- summary: partials={len(partials)} finals/filtered={len(finals)} "
        f"T-02={'PASS' if t02 else 'FAIL'} T-03={'PASS' if t03 else 'FAIL'} ---"
    )
    if not t02:
        print(
            "hint: T-02 需要在 session 期间对着麦克风清晰说话（安静环境 RMS 可能低于 VAD 阈值）",
            file=sys.stderr,
        )
    return 0 if (t02 and t03) else 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="macosAsr daemon CLI test client")
    parser.add_argument("--socket", type=Path, default=DEFAULT_SOCKET)
    parser.add_argument("--ping", action="store_true", help="Send ping and print pong")
    parser.add_argument(
        "--session-test",
        action="store_true",
        help="session_start, wait, session_stop; expect partial/final events",
    )
    parser.add_argument("--duration", type=float, default=5.0, help="Listen seconds after session_start")
    args = parser.parse_args(argv)

    if not args.socket.exists():
        print(f"socket not found: {args.socket}", file=sys.stderr)
        print("Start daemon first: python -m asr_daemon", file=sys.stderr)
        return 1

    if args.ping:
        return cmd_ping(args.socket)
    if args.session_test:
        return cmd_session_test(args.socket, args.duration)

    parser.print_help()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
