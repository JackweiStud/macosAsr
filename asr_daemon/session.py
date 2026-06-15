"""Session controller — bridges IPC and PartialEngine."""

from __future__ import annotations

import logging
import time
import uuid
from typing import Callable

from asr.config import AsrConfig
from asr.partial_engine import EventCallback, PartialEngine

EventEmitter = Callable[[dict], None]

logger = logging.getLogger(__name__)


class SessionController(EventCallback):
    def __init__(
        self,
        engine: PartialEngine,
        config: AsrConfig,
        emit: EventEmitter,
    ) -> None:
        self._engine = engine
        self._config = config
        self._emit = emit
        self._session_id: str | None = None

    @property
    def session_id(self) -> str | None:
        return self._session_id

    def start_session(self, language: str | None = None) -> str:
        if self._session_id is not None:
            logger.warning("session already active: %s", self._session_id)
            return self._session_id

        if language:
            self._config.language = language

        self._session_id = f"s-{uuid.uuid4().hex[:8]}"
        self._engine.start_recording()
        self._engine.set_listening(True)
        self._emit(
            {
                "protocol": 1,
                "type": "session_started",
                "session_id": self._session_id,
            }
        )
        logger.info("session_started id=%s lang=%s", self._session_id, self._config.language)
        return self._session_id

    def stop_session(self) -> None:
        if self._session_id is None:
            return

        sid = self._session_id
        self._engine.set_listening(False)
        self._engine.flush_on_stop()
        self._engine.stop_recording()
        self._session_id = None
        self._emit(
            {
                "protocol": 1,
                "type": "session_stopped",
                "session_id": sid,
            }
        )
        logger.info("session_stopped id=%s", sid)

    def on_partial(self, utterance_id: int, text: str) -> None:
        if self._session_id is None:
            return
        self._emit(
            {
                "protocol": 1,
                "type": "partial",
                "session_id": self._session_id,
                "utterance_id": utterance_id,
                "text": text,
                "ts": time.time(),
            }
        )

    def on_final(self, utterance_id: int, text: str) -> None:
        if self._session_id is None:
            return
        self._emit(
            {
                "protocol": 1,
                "type": "final",
                "session_id": self._session_id,
                "utterance_id": utterance_id,
                "text": text,
                "ts": time.time(),
            }
        )

    def on_filtered(self, utterance_id: int, text: str, reason: str) -> None:
        if self._session_id is None:
            return
        self._emit(
            {
                "protocol": 1,
                "type": "filtered",
                "session_id": self._session_id,
                "utterance_id": utterance_id,
                "text": text,
                "reason": reason,
                "ts": time.time(),
            }
        )

    def on_error(self, message: str) -> None:
        self._emit(
            {
                "protocol": 1,
                "type": "error",
                "message": message,
            }
        )

    def status_payload(self) -> dict:
        return {
            "protocol": 1,
            "type": "status",
            "listening": self._engine.is_listening(),
            "session_id": self._session_id,
            "model": self._config.model,
            "calibrated": self._engine.calibrated,
            "warmed_up": self._engine.warmed_up,
            "recording_active": self._engine.recording_active,
            "language": self._config.language,
        }
