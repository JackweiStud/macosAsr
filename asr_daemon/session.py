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
        self._base_system_prompt = config.system_prompt
        self._previous_final_text = ""

    @property
    def session_id(self) -> str | None:
        return self._session_id

    def start_session(self, language: str | None = None) -> str:
        if self._session_id is not None:
            logger.warning("session already active: %s", self._session_id)
            return self._session_id

        if language:
            self._config.language = language

        self._reset_previous_final_context()
        try:
            self._engine.start_recording()
        except Exception:
            logger.exception("start_recording failed")
            raise
        self._session_id = f"s-{uuid.uuid4().hex[:8]}"
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
        self._reset_previous_final_context()
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
        self._update_previous_final_context(text)

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

    def on_warning(self, message: str, code: str = "") -> None:
        self._emit(
            {
                "protocol": 1,
                "type": "warning",
                "message": message,
                "code": code,
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

    def _reset_previous_final_context(self) -> None:
        self._previous_final_text = ""
        self._apply_dynamic_system_prompt()

    def _update_previous_final_context(self, text: str) -> None:
        if not self._config.previous_final_context_enabled:
            return

        limit = max(0, self._config.previous_final_context_chars)
        normalized = " ".join(text.strip().split())
        self._previous_final_text = normalized[-limit:] if limit > 0 else ""
        self._apply_dynamic_system_prompt()
        logger.debug("previous final context chars=%s", len(self._previous_final_text))

    def _apply_dynamic_system_prompt(self) -> None:
        if not self._config.previous_final_context_enabled or not self._previous_final_text:
            self._config.system_prompt = self._base_system_prompt
            return

        parts = []
        if self._base_system_prompt:
            parts.append(self._base_system_prompt)
        parts.append(f"前文：{self._previous_final_text}")
        self._config.system_prompt = "\n".join(parts)
