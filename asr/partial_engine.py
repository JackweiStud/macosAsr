"""Partial-first VAD engine — derived from ASR-QWEN test_qwen3_asr_partial_first.py."""

from __future__ import annotations

import dataclasses
import logging
import queue
import threading
import time
from collections import deque
from collections.abc import Callable
from typing import Deque, Optional, Protocol

import numpy as np

from asr.asr_core import (
    AudioBlock,
    audio_rms,
    generate_utterance_text,
    load_model,
    require_runtime_dependencies,
    should_drop_final_text,
    stream_utterance_text,
    warm_up_asr_model,
)
from asr.config import AsrConfig

try:
    import sounddevice as sd
except ImportError:  # pragma: no cover
    sd = None

logger = logging.getLogger(__name__)


class EventCallback(Protocol):
    def on_partial(self, utterance_id: int, text: str) -> None: ...
    def on_final(self, utterance_id: int, text: str) -> None: ...
    def on_filtered(self, utterance_id: int, text: str, reason: str) -> None: ...
    def on_error(self, message: str) -> None: ...


@dataclasses.dataclass
class _UtteranceState:
    blocks: list[AudioBlock]
    started_at: float
    last_voice_at: float
    silence_run_seconds: float = 0.0
    last_partial_at: float = 0.0
    partial_count: int = 0
    first_partial_at: float | None = None
    last_partial_text: str = ""


class PartialEngine:
    """Mic always on; VAD/ASR runs only when listening=True.

    MLX inference must stay on the worker thread that loads the model
    (see RuntimeError: There is no Stream(gpu, 1) in current thread).
    """

    def __init__(
        self,
        config: AsrConfig,
        callback: EventCallback,
    ) -> None:
        self._model = None
        self._config = config
        self._callback = callback
        self._audio_queue: queue.Queue[AudioBlock] = queue.Queue(maxsize=1024)
        self._control_queue: queue.Queue[tuple[str, threading.Event] | str] = queue.Queue()
        self._listening = False
        self._utterance_id = 0
        self._utterance: Optional[_UtteranceState] = None
        self._pre_roll: Deque[AudioBlock] = deque()
        self._voiced_run_seconds = 0.0
        self._active_threshold = 0.0
        self._measured_noise_floor = 0.0
        self._calibrated = False
        self._model_loaded = False
        self._warmed_up = False
        self._stream: object | None = None
        self._thread: threading.Thread | None = None
        self._stop_event = threading.Event()
        self._lock = threading.Lock()

    @property
    def model_loaded(self) -> bool:
        return self._model_loaded

    @property
    def calibrated(self) -> bool:
        return self._calibrated

    @property
    def warmed_up(self) -> bool:
        return self._warmed_up

    @property
    def active_threshold(self) -> float:
        return self._active_threshold

    def set_listening(self, listening: bool) -> None:
        with self._lock:
            self._listening = listening
        logger.info("listening=%s", listening)

    def is_listening(self) -> bool:
        with self._lock:
            return self._listening

    def flush_on_stop(self) -> None:
        """Force-finalize the active utterance (PTT key-up) on the MLX worker thread."""
        done = threading.Event()
        self._control_queue.put(("flush", done))
        if not done.wait(timeout=30.0):
            logger.warning("flush_on_stop timed out waiting for worker")

    def start_background_mic(self) -> None:
        require_runtime_dependencies()
        assert sd is not None
        if self._thread is not None and self._thread.is_alive():
            return

        cfg = self._config
        block_seconds = cfg.input_block_seconds
        blocksize = max(160, int(cfg.sample_rate * block_seconds))
        pre_roll_blocks = max(1, int(round(cfg.vad_pre_roll_seconds / block_seconds)))
        self._pre_roll = deque(maxlen=pre_roll_blocks)

        def callback(indata, frames, time_info, status):  # pragma: no cover
            if status:
                logger.warning("audio status: %s", status)
            block = AudioBlock(
                samples=indata[:, 0].astype(np.float32, copy=True),
                captured_at=time.perf_counter(),
            )
            try:
                self._audio_queue.put_nowait(block)
            except queue.Full:
                pass

        input_kwargs: dict = {
            "samplerate": cfg.sample_rate,
            "channels": 1,
            "dtype": "float32",
            "blocksize": blocksize,
            "callback": callback,
        }
        if cfg.device is not None:
            input_kwargs["device"] = cfg.device

        self._stream = sd.InputStream(**input_kwargs)
        self._stream.start()  # type: ignore[union-attr]
        self._stop_event.clear()
        self._thread = threading.Thread(target=self._worker_loop, name="partial-engine-worker", daemon=True)
        self._thread.start()
        logger.info("background mic started blocksize=%s", blocksize)

    def stop(self) -> None:
        self._stop_event.set()
        if self._stream is not None:
            try:
                self._stream.stop()  # type: ignore[union-attr]
                self._stream.close()  # type: ignore[union-attr]
            except Exception as exc:  # pragma: no cover
                logger.warning("stop mic stream: %s", exc)
            self._stream = None
        if self._thread is not None:
            self._thread.join(timeout=5.0)
            self._thread = None

    def _worker_loop(self) -> None:
        cfg = self._config
        end_silence_threshold = max(0.05, cfg.vad_end_silence_seconds)

        try:
            logger.info("loading model on worker thread: %s", cfg.model)
            self._model = load_model(cfg.model)
            if cfg.warmup_enabled:
                try:
                    stats = warm_up_asr_model(self._model, cfg)
                    self._warmed_up = True
                    logger.info(
                        "ASR warmup complete stream_ms=%.1f generate_ms=%.1f",
                        stats["stream_ms"],
                        stats["generate_ms"],
                    )
                except Exception:
                    self._warmed_up = False
                    logger.exception("ASR warmup failed; continuing without warmup")
            self._model_loaded = True
            self._calibrate_noise(cfg)
            while not self._stop_event.is_set():
                self._drain_control_queue()
                self._drain_audio_blocks()
                if not self.is_listening():
                    time.sleep(0.01)
                    continue
                self._process_active_utterance(end_silence_threshold)
                time.sleep(0.01)
        except Exception as exc:
            logger.exception("worker loop failed")
            self._callback.on_error(str(exc))

    def _drain_control_queue(self) -> None:
        while True:
            try:
                cmd = self._control_queue.get_nowait()
            except queue.Empty:
                break
            if isinstance(cmd, tuple) and cmd[0] == "flush":
                _, done = cmd
                with self._lock:
                    utterance = self._utterance
                    self._utterance = None
                    self._pre_roll.clear()
                    self._voiced_run_seconds = 0.0
                if utterance is not None:
                    self._finalize_utterance(utterance, force_short=True)
                done.set()

    def _calibrate_noise(self, cfg: AsrConfig) -> None:
        if cfg.noise_calibration_seconds <= 0:
            self._measured_noise_floor = 0.0
            self._set_threshold(cfg, 0.0)
            self._calibrated = True
            return

        logger.info("Calibrating noise for %.1fs — stay quiet", cfg.noise_calibration_seconds)
        calibration_deadline = time.perf_counter() + cfg.noise_calibration_seconds
        calibration_rms: list[float] = []
        while time.perf_counter() < calibration_deadline and not self._stop_event.is_set():
            remaining = max(0.0, calibration_deadline - time.perf_counter())
            timeout = min(0.1, remaining) if remaining > 0 else 0.1
            try:
                block = self._audio_queue.get(timeout=timeout)
            except queue.Empty:
                continue
            calibration_rms.append(audio_rms(block.samples))
            self._pre_roll.append(block)

        measured = float(np.percentile(calibration_rms, 90)) if calibration_rms else 0.0
        self._measured_noise_floor = measured
        self._set_threshold(cfg, measured)
        self._calibrated = True
        logger.info(
            "VAD threshold=%.3f noise_floor=%.4f",
            self._active_threshold,
            self._measured_noise_floor,
        )

    def _set_threshold(self, cfg: AsrConfig, measured_noise_floor: float) -> None:
        if cfg.vad_rms_threshold > 0:
            self._active_threshold = cfg.vad_rms_threshold
        else:
            raw = max(
                cfg.noise_margin,
                measured_noise_floor * cfg.noise_multiplier + cfg.noise_margin,
            )
            cap = cfg.noise_max_threshold if cfg.noise_max_threshold > 0 else raw
            self._active_threshold = min(raw, cap)

    def _drain_audio_blocks(self) -> None:
        cfg = self._config
        listening = self.is_listening()
        start_speech_threshold = max(cfg.input_block_seconds, cfg.vad_start_speech_seconds)

        while True:
            try:
                block = self._audio_queue.get_nowait()
            except queue.Empty:
                break

            block_rms = audio_rms(block.samples)
            self._pre_roll.append(block)

            if not listening:
                continue

            with self._lock:
                utterance = self._utterance
                if utterance is None:
                    if block_rms >= self._active_threshold:
                        self._voiced_run_seconds += len(block.samples) / float(cfg.sample_rate)
                        if self._voiced_run_seconds >= start_speech_threshold:
                            self._utterance = _UtteranceState(
                                blocks=list(self._pre_roll),
                                started_at=self._pre_roll[0].captured_at if self._pre_roll else block.captured_at,
                                last_voice_at=block.captured_at,
                            )
                            self._voiced_run_seconds = 0.0
                            logger.debug("utterance started")
                    else:
                        self._voiced_run_seconds = 0.0
                    continue

                utterance.blocks.append(block)
                if block_rms >= self._active_threshold:
                    utterance.last_voice_at = block.captured_at
                    utterance.silence_run_seconds = 0.0
                else:
                    utterance.silence_run_seconds += len(block.samples) / float(cfg.sample_rate)

    def _process_active_utterance(self, end_silence_threshold: float) -> None:
        cfg = self._config
        assert self._model is not None
        now = time.perf_counter()

        with self._lock:
            utterance = self._utterance

        if utterance is None:
            return

        utterance_seconds = sum(len(b.samples) for b in utterance.blocks) / float(cfg.sample_rate)

        if (
            utterance_seconds >= cfg.partial_min_audio_seconds
            and now - utterance.last_partial_at >= cfg.partial_interval_seconds
        ):
            partial_call_at = time.perf_counter()
            partial_text = stream_utterance_text(self._model, utterance.blocks, cfg)
            utterance.last_partial_at = partial_call_at
            if partial_text and partial_text != utterance.last_partial_text:
                utterance.partial_count += 1
                utterance.last_partial_text = partial_text
                if utterance.first_partial_at is None:
                    utterance.first_partial_at = partial_call_at
                self._emit_partial(partial_text)

        if utterance.silence_run_seconds >= end_silence_threshold:
            with self._lock:
                self._utterance = None
                self._pre_roll.clear()
                self._voiced_run_seconds = 0.0
            if utterance_seconds < cfg.vad_min_utterance_seconds:
                return
            self._finalize_utterance(utterance)
            return

        if cfg.vad_max_utterance_seconds > 0 and utterance_seconds >= cfg.vad_max_utterance_seconds:
            with self._lock:
                self._utterance = None
                self._pre_roll.clear()
                self._voiced_run_seconds = 0.0
            self._finalize_utterance(utterance)

    def _emit_partial(self, text: str) -> None:
        self._utterance_id += 1
        uid = self._utterance_id
        logger.debug("partial u=%s len=%s", uid, len(text))
        self._callback.on_partial(uid, text)

    def _finalize_utterance(self, utterance: _UtteranceState, *, force_short: bool = False) -> None:
        cfg = self._config
        assert self._model is not None
        utterance_seconds = sum(len(b.samples) for b in utterance.blocks) / float(cfg.sample_rate)
        if not force_short and utterance_seconds < cfg.vad_min_utterance_seconds:
            return

        final_text = generate_utterance_text(self._model, utterance.blocks, cfg)
        uid = self._utterance_id if self._utterance_id else 1

        if final_text and should_drop_final_text(final_text, cfg):
            reason = "filler_or_short"
            logger.debug("filtered u=%s reason=%s", uid, reason)
            self._callback.on_filtered(uid, final_text, reason)
        elif final_text:
            logger.debug("final u=%s len=%s", uid, len(final_text))
            self._callback.on_final(uid, final_text)
        else:
            self._callback.on_filtered(uid, "", "empty")
