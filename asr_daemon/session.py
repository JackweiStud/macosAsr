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
        self._session_context = ""
        self._previous_final_text = ""

    @property
    def session_id(self) -> str | None:
        return self._session_id

    def update_base_context(self, base_prompt: str) -> None:
        self._base_system_prompt = base_prompt.strip()
        self._apply_dynamic_system_prompt()
        logger.info("base_context_updated chars=%s", len(self._base_system_prompt))

    def start_session(
        self,
        language: str | None = None,
        session_context: str | None = None,
    ) -> str:
        if self._session_id is not None:
            logger.warning("session already active: %s", self._session_id)
            # Reconnecting clients still need an acknowledgement. They must discard
            # pre-reconnect audio before accepting results from this resumed session.
            self._emit({
                "protocol": 1,
                "type": "session_started",
                "session_id": self._session_id,
                "resumed": True,
            })
            return self._session_id

        if language:
            self._config.language = language

        self._previous_final_text = ""
        self._session_context = self._normalize_session_context(session_context)
        self._apply_dynamic_system_prompt()
        try:
            self._engine.start_recording()
        except Exception:
            self._reset_previous_final_context()
            logger.exception("start_recording failed")
            raise
        self._session_id = f"s-{uuid.uuid4().hex[:8]}"
        self._emit(
            {
                "protocol": 1,
                "type": "session_started",
                "session_id": self._session_id,
            }
        )
        self._engine.set_listening(True)
        logger.info(
            "session_started id=%s lang=%s base_ctx_chars=%s session_ctx_chars=%s",
            self._session_id,
            self._config.language,
            len(self._base_system_prompt),
            len(self._session_context),
        )
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

    def discard_utterance(self, session_id: str, before: float) -> bool:
        if self._session_id is None or session_id != self._session_id:
            return False
        self._reset_previous_final_context()
        self._engine.discard_utterance(before)
        return True

    def on_partial(self, utterance_id: int, text: str, utterance_started_at: float) -> None:
        if self._session_id is None:
            return
        self._emit(
            {
                "protocol": 1,
                "type": "partial",
                "session_id": self._session_id,
                "utterance_id": utterance_id,
                "utterance_started_at": utterance_started_at,
                "text": text,
                "ts": time.time(),
            }
        )

    def on_final(self, utterance_id: int, text: str, utterance_started_at: float) -> None:
        if self._session_id is None:
            return
        self._emit(
            {
                "protocol": 1,
                "type": "final",
                "session_id": self._session_id,
                "utterance_id": utterance_id,
                "utterance_started_at": utterance_started_at,
                "text": text,
                "ts": time.time(),
            }
        )
        self._update_previous_final_context(text)

    def on_filtered(self, utterance_id: int, text: str, reason: str, utterance_started_at: float) -> None:
        if self._session_id is None:
            return
        self._emit(
            {
                "protocol": 1,
                "type": "filtered",
                "session_id": self._session_id,
                "utterance_id": utterance_id,
                "utterance_started_at": utterance_started_at,
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

    def on_audio_level(self, level: float, speaking: bool) -> None:
        if self._session_id is None:
            return
        self._emit(
            {
                "protocol": 1,
                "type": "audio_level",
                "session_id": self._session_id,
                "level": round(max(0.0, min(1.0, float(level))), 3),
                "speaking": bool(speaking),
            }
        )

    def on_polishing(self, utterance_id: int) -> None:
        if self._session_id is None:
            return
        self._emit(
            {
                "protocol": 1,
                "type": "polishing",
                "session_id": self._session_id,
                "utterance_id": utterance_id,
            }
        )

    def on_calibration_started(self, duration_seconds: float) -> None:
        self._emit(
            {
                "protocol": 1,
                "type": "calibration_started",
                "duration_seconds": round(float(duration_seconds), 2),
            }
        )

    def on_calibration_done(self, noise_floor: float, threshold: float) -> None:
        self._emit(
            {
                "protocol": 1,
                "type": "calibration_done",
                "noise_floor": round(float(noise_floor), 5),
                "threshold": round(float(threshold), 5),
            }
        )

    def on_calibration_failed(self, message: str) -> None:
        self._emit(
            {
                "protocol": 1,
                "type": "calibration_failed",
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
            "noise_floor": round(float(getattr(self._engine, "noise_floor", 0.0)), 5),
            "vad_threshold": round(float(getattr(self._engine, "active_threshold", 0.0)), 5),
        }

    def _normalize_session_context(self, session_context: str | None) -> str:
        if not isinstance(session_context, str):
            return ""
        normalized = " ".join(session_context.strip().split())
        return normalized[:240]

    def _reset_previous_final_context(self) -> None:
        self._previous_final_text = ""
        self._session_context = ""
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
        parts: list[str] = []
        if self._base_system_prompt:
            parts.append(self._base_system_prompt)
        if self._session_context:
            parts.append(self._session_context)
        if self._config.previous_final_context_enabled and self._previous_final_text:
            parts.append(f"前文：{self._previous_final_text}")
        self._config.system_prompt = "\n".join(parts)
