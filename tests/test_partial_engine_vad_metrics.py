from __future__ import annotations

import unittest
from unittest.mock import patch

import numpy as np

from asr.asr_core import AudioBlock
from asr.config import AsrConfig
from asr.partial_engine import PartialEngine


class _RecordingCallback:
    def __init__(self) -> None:
        self.events: list[tuple[str, int, str]] = []

    def on_partial(self, utterance_id: int, text: str) -> None:
        self.events.append(("partial", utterance_id, text))

    def on_final(self, utterance_id: int, text: str) -> None:
        self.events.append(("final", utterance_id, text))

    def on_filtered(self, utterance_id: int, text: str, reason: str) -> None:
        self.events.append(("filtered", utterance_id, reason))

    def on_error(self, message: str) -> None:
        self.events.append(("error", -1, message))


class PartialEngineVadMetricsTests(unittest.TestCase):
    def test_relative_silence_finalizes_pause_when_noise_is_above_absolute_threshold(self) -> None:
        config = AsrConfig(
            sample_rate=10,
            input_block_seconds=0.1,
            partial_interval_seconds=999.0,
            partial_min_audio_seconds=999.0,
            vad_start_speech_seconds=0.1,
            vad_end_silence_seconds=0.2,
            vad_min_utterance_seconds=0.1,
            vad_relative_silence_ratio=0.4,
            filter_fillers=False,
            min_final_chars=1,
        )
        callback = _RecordingCallback()
        engine = PartialEngine(config, callback)
        engine._model = object()
        engine._active_threshold = 0.1
        engine.set_listening(True)

        speech = np.full(1, 0.5, dtype=np.float32)
        background_noise = np.full(1, 0.15, dtype=np.float32)

        with patch("asr.partial_engine.generate_utterance_text", return_value="first sentence"):
            engine._audio_queue.put(AudioBlock(samples=speech, captured_at=1.0))
            engine._drain_audio_blocks()
            engine._process_active_utterance(end_silence_threshold=0.2)

            engine._audio_queue.put(AudioBlock(samples=background_noise, captured_at=1.1))
            engine._drain_audio_blocks()
            engine._process_active_utterance(end_silence_threshold=0.2)

            engine._audio_queue.put(AudioBlock(samples=background_noise, captured_at=1.2))
            engine._drain_audio_blocks()
            engine._process_active_utterance(end_silence_threshold=0.2)

        self.assertEqual(callback.events, [("final", 1, "first sentence")])

    def test_partial_and_final_metrics_are_logged_without_transcript_text(self) -> None:
        config = AsrConfig(
            sample_rate=10,
            input_block_seconds=0.1,
            partial_interval_seconds=0.0,
            partial_min_audio_seconds=0.1,
            vad_start_speech_seconds=0.1,
            vad_end_silence_seconds=0.1,
            vad_min_utterance_seconds=0.1,
            filter_fillers=False,
            min_final_chars=1,
        )
        callback = _RecordingCallback()
        engine = PartialEngine(config, callback)
        engine._model = object()
        engine._active_threshold = 0.1
        engine.set_listening(True)

        speech = np.full(1, 0.5, dtype=np.float32)
        silence = np.zeros(1, dtype=np.float32)

        with (
            patch("asr.partial_engine.stream_utterance_text", return_value="private partial text"),
            patch("asr.partial_engine.generate_utterance_text", return_value="private final text"),
            self.assertLogs("asr.partial_engine", level="INFO") as logs,
        ):
            engine._audio_queue.put(AudioBlock(samples=speech, captured_at=1.0))
            engine._drain_audio_blocks()
            engine._process_active_utterance(end_silence_threshold=0.1)

            engine._audio_queue.put(AudioBlock(samples=silence, captured_at=1.1))
            engine._drain_audio_blocks()
            engine._process_active_utterance(end_silence_threshold=0.1)

        joined = "\n".join(logs.output)
        self.assertIn("utterance_started", joined)
        self.assertIn("partial_metrics", joined)
        self.assertIn("final_metrics", joined)
        self.assertIn("first_partial_ms=", joined)
        self.assertIn("partial_ms=", joined)
        self.assertIn("final_ms=", joined)
        self.assertIn("utterance_seconds=", joined)
        self.assertIn("partial_count=", joined)
        self.assertNotIn("private partial text", joined)
        self.assertNotIn("private final text", joined)


if __name__ == "__main__":
    unittest.main()
