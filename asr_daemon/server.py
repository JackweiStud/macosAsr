"""Unix domain socket server — JSON-lines IPC (SDD §5)."""

from __future__ import annotations

import json
import logging
import os
import socket
import threading
from pathlib import Path
from typing import Callable

from asr.asr_core import require_runtime_dependencies
from asr.config import AsrConfig
from asr.partial_engine import EventCallback, PartialEngine
from asr_daemon.session import SessionController

logger = logging.getLogger(__name__)

EventEmitter = Callable[[dict], None]
PROTOCOL_VERSION = 1


class _CallbackBridge(EventCallback):
    """Deferred binding so PartialEngine can register SessionController as handler."""

    def __init__(self) -> None:
        self._target: EventCallback | None = None

    def bind(self, target: EventCallback) -> None:
        self._target = target

    def on_partial(self, utterance_id: int, text: str) -> None:
        if self._target:
            self._target.on_partial(utterance_id, text)

    def on_final(self, utterance_id: int, text: str) -> None:
        if self._target:
            self._target.on_final(utterance_id, text)

    def on_filtered(self, utterance_id: int, text: str, reason: str) -> None:
        if self._target:
            self._target.on_filtered(utterance_id, text, reason)

    def on_error(self, message: str) -> None:
        if self._target:
            self._target.on_error(message)


class DaemonServer:
    def __init__(self, socket_path: Path, config: AsrConfig, *, skip_model: bool = False) -> None:
        self._socket_path = socket_path
        self._config = config
        self._skip_model = skip_model
        self._engine: PartialEngine | None = None
        self._session: SessionController | None = None
        self._clients: list[socket.socket] = []
        self._clients_lock = threading.Lock()
        self._running = False
        self._server_sock: socket.socket | None = None

    @property
    def model_loaded(self) -> bool:
        return self._engine.model_loaded if self._engine else False

    def start(self) -> None:
        if not self._skip_model:
            require_runtime_dependencies()
            bridge = _CallbackBridge()
            self._engine = PartialEngine(self._config, bridge)
            self._session = SessionController(self._engine, self._config, self._broadcast)
            bridge.bind(self._session)
            self._engine.start_background_mic()

        self._socket_path.parent.mkdir(parents=True, exist_ok=True)
        if self._socket_path.exists():
            self._socket_path.unlink()

        self._server_sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self._server_sock.bind(str(self._socket_path))
        os.chmod(self._socket_path, 0o600)
        self._server_sock.listen(4)
        self._running = True
        logger.info("daemon listening on %s", self._socket_path)

        while self._running:
            try:
                self._server_sock.settimeout(1.0)
                conn, _ = self._server_sock.accept()
            except TimeoutError:
                continue
            except OSError:
                if self._running:
                    logger.exception("accept failed")
                break
            threading.Thread(
                target=self._handle_client,
                args=(conn,),
                name="daemon-client",
                daemon=True,
            ).start()

    def stop(self) -> None:
        self._running = False
        if self._session is not None:
            self._session.stop_session()
        if self._engine is not None:
            self._engine.stop()
        if self._server_sock:
            try:
                self._server_sock.close()
            except OSError:
                pass
        with self._clients_lock:
            for c in self._clients:
                try:
                    c.close()
                except OSError:
                    pass
            self._clients.clear()
        if self._socket_path.exists():
            try:
                self._socket_path.unlink()
            except OSError:
                pass

    def _broadcast(self, event: dict) -> None:
        line = json.dumps(event, ensure_ascii=False) + "\n"
        data = line.encode("utf-8")
        with self._clients_lock:
            dead: list[socket.socket] = []
            for conn in self._clients:
                try:
                    conn.sendall(data)
                except OSError:
                    dead.append(conn)
            for conn in dead:
                self._clients.remove(conn)

    def _handle_client(self, conn: socket.socket) -> None:
        with self._clients_lock:
            self._clients.append(conn)
        logger.info("client connected")
        buffer = ""
        try:
            while self._running:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                buffer += chunk.decode("utf-8", errors="replace")
                while "\n" in buffer:
                    line, buffer = buffer.split("\n", 1)
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        msg = json.loads(line)
                    except json.JSONDecodeError as exc:
                        self._send(conn, {"protocol": 1, "type": "error", "message": f"invalid json: {exc}"})
                        continue
                    for event in self._dispatch(msg):
                        self._send(conn, event)
        except OSError as exc:
            logger.debug("client disconnected: %s", exc)
        finally:
            with self._clients_lock:
                if conn in self._clients:
                    self._clients.remove(conn)
            try:
                conn.close()
            except OSError:
                pass

    def _send(self, conn: socket.socket, event: dict) -> None:
        line = json.dumps(event, ensure_ascii=False) + "\n"
        try:
            conn.sendall(line.encode("utf-8"))
        except OSError as exc:
            logger.warning("send failed: %s", exc)

    def _dispatch(self, msg: dict) -> list[dict]:
        if msg.get("protocol") != PROTOCOL_VERSION:
            return [{"protocol": 1, "type": "error", "message": "unsupported protocol", "code": "bad_protocol"}]

        cmd = msg.get("cmd")
        if cmd == "ping":
            return [
                {
                    "protocol": 1,
                    "type": "pong",
                    "model_loaded": self.model_loaded,
                    "calibrated": self._engine.calibrated if self._engine else False,
                }
            ]
        if cmd == "get_status":
            if self._session is None:
                return [
                    {
                        "protocol": 1,
                        "type": "status",
                        "listening": False,
                        "model": self._config.model,
                        "calibrated": False,
                    }
                ]
            return [self._session.status_payload()]

        if self._session is None:
            return [{"protocol": 1, "type": "error", "message": "model not loaded", "code": "no_model"}]

        if cmd == "session_start":
            self._session.start_session(language=msg.get("language"))
            return []
        if cmd == "session_stop":
            self._session.stop_session()
            return []
        if cmd == "shutdown":
            threading.Thread(target=self.stop, daemon=True).start()
            return [{"protocol": 1, "type": "error", "message": "shutting down", "code": "shutdown"}]

        return [{"protocol": 1, "type": "error", "message": f"unknown cmd: {cmd}", "code": "unknown_cmd"}]
