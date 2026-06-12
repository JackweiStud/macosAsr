from __future__ import annotations

import unittest
from unittest.mock import Mock, patch

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


class PartialEngineUtteranceIdTests(unittest.TestCase):
    def test_partial_and_final_events_share_one_utterance_id(self) -> None:
        config = AsrConfig(
            sample_rate=10,
            input_block_seconds=0.1,
            partial_interval_seconds=0.0,
            partial_min_audio_seconds=0.1,
            vad_start_speech_seconds=0.1,
            vad_min_utterance_seconds=0.1,
            filter_fillers=False,
            min_final_chars=1,
        )
        callback = _RecordingCallback()
        engine = PartialEngine(config, callback)
        engine._model = object()
        engine._active_threshold = 0.1
        engine.set_listening(True)

        speech = np.full(10, 0.5, dtype=np.float32)
        silence = np.zeros(10, dtype=np.float32)
        partials = iter(["hello", "hello world", "hello world"])

        with (
            patch("asr.partial_engine.stream_utterance_text", side_effect=lambda *_: next(partials)),
            patch("asr.partial_engine.generate_utterance_text", return_value="hello world final"),
        ):
            engine._audio_queue.put(AudioBlock(samples=speech, captured_at=1.0))
            engine._drain_audio_blocks()
            engine._process_active_utterance(end_silence_threshold=0.1)

            engine._audio_queue.put(AudioBlock(samples=speech, captured_at=2.0))
            engine._drain_audio_blocks()
            engine._process_active_utterance(end_silence_threshold=0.1)

            engine._audio_queue.put(AudioBlock(samples=silence, captured_at=3.0))
            engine._drain_audio_blocks()
            engine._process_active_utterance(end_silence_threshold=0.1)

        self.assertEqual(
            callback.events,
            [
                ("partial", 1, "hello"),
                ("partial", 1, "hello world"),
                ("final", 1, "hello world final"),
            ],
        )

    def test_partial_stops_after_max_audio_window_but_final_still_emits(self) -> None:
        config = AsrConfig(
            sample_rate=10,
            input_block_seconds=0.1,
            partial_interval_seconds=0.0,
            partial_min_audio_seconds=0.1,
            partial_max_audio_seconds=0.15,
            vad_start_speech_seconds=0.1,
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
        stream = Mock(return_value="hello")

        with (
            patch("asr.partial_engine.stream_utterance_text", stream),
            patch("asr.partial_engine.generate_utterance_text", return_value="hello final"),
        ):
            engine._audio_queue.put(AudioBlock(samples=speech, captured_at=1.0))
            engine._drain_audio_blocks()
            engine._process_active_utterance(end_silence_threshold=0.1)

            engine._audio_queue.put(AudioBlock(samples=speech, captured_at=2.0))
            engine._drain_audio_blocks()
            engine._process_active_utterance(end_silence_threshold=0.1)

            engine._audio_queue.put(AudioBlock(samples=silence, captured_at=3.0))
            engine._drain_audio_blocks()
            engine._process_active_utterance(end_silence_threshold=0.1)

        self.assertEqual(stream.call_count, 1)
        self.assertEqual(
            callback.events,
            [
                ("partial", 1, "hello"),
                ("final", 1, "hello final"),
            ],
        )


if __name__ == "__main__":
    unittest.main()
