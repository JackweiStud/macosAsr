from __future__ import annotations

import unittest
from unittest.mock import Mock, patch

import numpy as np

from asr.asr_core import AudioBlock
from asr.config import AsrConfig
import asr.partial_engine as partial_engine
from asr.partial_engine import PartialEngine


class _RecordingCallback:
    def __init__(self) -> None:
        self.events: list[tuple[str, int, str]] = []

    def on_partial(self, utterance_id: int, text: str, utterance_started_at: float) -> None:
        self.events.append(("partial", utterance_id, text))

    def on_final(self, utterance_id: int, text: str, utterance_started_at: float) -> None:
        self.events.append(("final", utterance_id, text))

    def on_filtered(self, utterance_id: int, text: str, reason: str, utterance_started_at: float) -> None:
        self.events.append(("filtered", utterance_id, reason))

    def on_error(self, message: str) -> None:
        self.events.append(("error", -1, message))

    def on_warning(self, message: str, code: str) -> None:
        self.events.append(("warning", -1, f"{code}:{message}"))


class PartialEngineUtteranceIdTests(unittest.TestCase):
    def test_boundary_decode_skips_redundant_partial_and_only_silence_is_final(self) -> None:
        cases = [
            ("silence", 0.3, {}),
            (
                "roll_silence",
                0.2,
                {
                    "partial_max_audio_seconds": 2.0,
                    "partial_roll_min_seconds": 0.5,
                    "partial_roll_silence_seconds": 0.1,
                },
            ),
            ("max_audio_window", 0.0, {"partial_max_audio_seconds": 0.5}),
            (
                "soft_silence",
                0.2,
                {
                    "vad_soft_max_utterance_seconds": 0.5,
                    "vad_soft_break_silence_seconds": 0.15,
                },
            ),
            ("max_utterance", 0.0, {"vad_max_utterance_seconds": 0.5}),
        ]
        for reason, silence_seconds, overrides in cases:
            with self.subTest(reason=reason):
                settings = dict(
                    sample_rate=10,
                    input_block_seconds=0.1,
                    partial_interval_seconds=0.0,
                    partial_min_audio_seconds=0.1,
                    partial_max_audio_seconds=0.0,
                    vad_min_utterance_seconds=0.1,
                    vad_soft_max_utterance_seconds=0.0,
                    vad_max_utterance_seconds=5.0,
                    filter_fillers=False,
                    min_final_chars=1,
                    final_audio_trim_enabled=False,
                )
                settings.update(overrides)
                callback = _RecordingCallback()
                engine = PartialEngine(AsrConfig(**settings), callback)
                engine._model = object()
                utterance = partial_engine._UtteranceState(
                    utterance_id=7,
                    blocks=[AudioBlock(samples=np.ones(10, dtype=np.float32), captured_at=0.0)],
                    started_at=0.0,
                    last_voice_at=0.0,
                    speech_started_at=0.0,
                    silence_run_seconds=silence_seconds,
                )
                engine._utterance = utterance

                with (
                    self.assertLogs("asr.partial_engine", level="INFO") as logs,
                    patch("asr.partial_engine.stream_utterance_text", return_value="partial") as stream,
                    patch("asr.partial_engine.generate_utterance_text", return_value="final") as generate,
                ):
                    engine._process_active_utterance(end_silence_threshold=0.3)

                stream.assert_not_called()
                generate.assert_called_once_with(engine._model, utterance.blocks, engine._config)
                event = "final" if reason == "silence" else "partial"
                self.assertEqual(callback.events, [(event, 7, "final")])
                self.assertIn(f"reason={reason}", "\n".join(logs.output))
                if reason == "silence":
                    self.assertIsNone(engine._utterance)
                else:
                    self.assertIs(engine._utterance, utterance)

    def test_partial_refresh_respects_interval_during_a_short_pause(self) -> None:
        config = AsrConfig(
            sample_rate=10,
            partial_interval_seconds=1.0,
            partial_min_audio_seconds=0.1,
            partial_max_audio_seconds=0.0,
            vad_min_utterance_seconds=0.1,
            vad_soft_max_utterance_seconds=1.0,
            vad_soft_break_silence_seconds=0.15,
            vad_max_utterance_seconds=2.0,
        )
        callback = _RecordingCallback()
        engine = PartialEngine(config, callback)
        engine._model = object()
        utterance = partial_engine._UtteranceState(
            utterance_id=7,
            blocks=[AudioBlock(samples=np.ones(5, dtype=np.float32), captured_at=0.0)],
            started_at=0.0,
            last_voice_at=0.0,
            speech_started_at=0.0,
            silence_run_seconds=0.1,
            last_partial_at=100.0,
        )
        engine._utterance = utterance

        with (
            patch("asr.partial_engine.time.perf_counter", return_value=100.5) as clock,
            patch("asr.partial_engine.stream_utterance_text", return_value="partial") as stream,
            patch("asr.partial_engine.generate_utterance_text") as generate,
        ):
            engine._process_active_utterance(end_silence_threshold=0.3)
            stream.assert_not_called()
            generate.assert_not_called()
            self.assertEqual(callback.events, [])
            self.assertIs(engine._utterance, utterance)

            clock.return_value = 101.0
            engine._process_active_utterance(end_silence_threshold=0.3)

        stream.assert_called_once_with(engine._model, utterance.blocks, config)
        generate.assert_not_called()
        self.assertEqual(callback.events, [("partial", 7, "partial")])
        self.assertIs(engine._utterance, utterance)

    def test_short_utterance_ending_in_silence_is_discarded_without_inference(self) -> None:
        config = AsrConfig(
            sample_rate=10,
            partial_interval_seconds=0.0,
            partial_min_audio_seconds=0.1,
            partial_max_audio_seconds=0.0,
            vad_min_utterance_seconds=0.4,
        )
        callback = _RecordingCallback()
        engine = PartialEngine(config, callback)
        engine._model = object()
        engine._utterance = partial_engine._UtteranceState(
            utterance_id=7,
            blocks=[AudioBlock(samples=np.ones(2, dtype=np.float32), captured_at=0.0)],
            started_at=0.0,
            last_voice_at=0.0,
            speech_started_at=0.0,
            silence_run_seconds=0.1,
        )

        with (
            patch("asr.partial_engine.stream_utterance_text", return_value="partial") as stream,
            patch("asr.partial_engine.generate_utterance_text") as generate,
        ):
            engine._process_active_utterance(end_silence_threshold=0.1)

        stream.assert_not_called()
        generate.assert_not_called()
        self.assertEqual(callback.events, [])
        self.assertIsNone(engine._utterance)

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

    def test_max_audio_window_checkpoints_without_semantic_final(self) -> None:
        config = AsrConfig(
            sample_rate=10,
            input_block_seconds=0.1,
            partial_interval_seconds=0.0,
            partial_min_audio_seconds=0.1,
            partial_max_audio_seconds=0.15,
            partial_roll_min_seconds=9.0,
            vad_start_speech_seconds=0.1,
            vad_min_utterance_seconds=0.1,
            vad_end_silence_seconds=5.0,
            filter_fillers=False,
            min_final_chars=1,
            final_audio_trim_enabled=False,
        )
        callback = _RecordingCallback()
        engine = PartialEngine(config, callback)
        engine._model = object()
        engine._active_threshold = 0.1
        engine.set_listening(True)

        speech = np.full(1, 0.5, dtype=np.float32)
        stream = Mock(return_value="hello")

        with (
            self.assertLogs("asr.partial_engine", level="INFO") as logs,
            patch("asr.partial_engine.stream_utterance_text", stream),
            patch("asr.partial_engine.generate_utterance_text", side_effect=["hello final", "final", "hello"]),
        ):
            engine._audio_queue.put(AudioBlock(samples=speech, captured_at=1.0))
            engine._drain_audio_blocks()
            engine._process_active_utterance(end_silence_threshold=5.0)

            engine._audio_queue.put(AudioBlock(samples=speech, captured_at=2.0))
            engine._drain_audio_blocks()
            engine._process_active_utterance(end_silence_threshold=5.0)

        self.assertEqual(stream.call_count, 1)
        self.assertEqual(
            callback.events,
            [
                ("partial", 1, "hello"),
                ("partial", 1, "hello final"),
            ],
        )
        self.assertIn("reason=max_audio_window", "\n".join(logs.output))
        self.assertIsNotNone(engine._utterance)
        self.assertEqual(engine._utterance.utterance_id, 1)

    def test_max_audio_window_preserves_utterance_for_following_speech(self) -> None:
        config = AsrConfig(
            sample_rate=10,
            input_block_seconds=0.1,
            partial_interval_seconds=0.0,
            partial_min_audio_seconds=0.1,
            partial_max_audio_seconds=0.15,
            partial_roll_min_seconds=9.0,
            vad_start_speech_seconds=0.1,
            vad_min_utterance_seconds=0.1,
            vad_end_silence_seconds=5.0,
            filter_fillers=False,
            min_final_chars=1,
            final_audio_trim_enabled=False,
        )
        callback = _RecordingCallback()
        engine = PartialEngine(config, callback)
        engine._model = object()
        engine._active_threshold = 0.1
        engine.set_listening(True)

        speech = np.full(1, 0.5, dtype=np.float32)
        partials = iter(["hello"])
        finals = iter(["hello final", "final", "hello", "final again", "again", "final"])

        with (
            patch("asr.partial_engine.stream_utterance_text", side_effect=lambda *_: next(partials)),
            patch("asr.partial_engine.generate_utterance_text", side_effect=lambda *_: next(finals)),
        ):
            engine._audio_queue.put(AudioBlock(samples=speech, captured_at=1.0))
            engine._drain_audio_blocks()
            engine._process_active_utterance(end_silence_threshold=5.0)

            engine._audio_queue.put(AudioBlock(samples=speech, captured_at=2.0))
            engine._drain_audio_blocks()
            engine._process_active_utterance(end_silence_threshold=5.0)

            engine._audio_queue.put(AudioBlock(samples=speech, captured_at=3.0))
            engine._drain_audio_blocks()
            engine._process_active_utterance(end_silence_threshold=5.0)

        self.assertEqual(
            callback.events,
            [
                ("partial", 1, "hello"),
                ("partial", 1, "hello final"),
                ("partial", 1, "hello final again"),
            ],
        )
        self.assertEqual(engine._utterance.utterance_id, 1)

    def test_short_pause_rolls_after_min_duration(self) -> None:
        config = AsrConfig(
            sample_rate=10,
            input_block_seconds=0.1,
            partial_min_audio_seconds=99.0,
            partial_max_audio_seconds=1.0,
            partial_roll_min_seconds=0.2,
            partial_roll_silence_seconds=0.1,
            vad_start_speech_seconds=0.1,
            vad_min_utterance_seconds=0.1,
            vad_end_silence_seconds=1.0,
            vad_soft_max_utterance_seconds=0.0,
            filter_fillers=False,
            min_final_chars=1,
            final_audio_trim_enabled=False,
        )
        callback = _RecordingCallback()
        engine = PartialEngine(config, callback)
        engine._model = object()
        engine._active_threshold = 0.1
        engine.set_listening(True)

        speech = np.full(1, 0.5, dtype=np.float32)
        silence = np.zeros(1, dtype=np.float32)

        with (
            self.assertLogs("asr.partial_engine", level="INFO") as logs,
            patch("asr.partial_engine.generate_utterance_text", return_value="rolled"),
        ):
            for block in [
                AudioBlock(samples=speech, captured_at=0.0),
                AudioBlock(samples=speech, captured_at=0.1),
                AudioBlock(samples=silence, captured_at=0.2),
            ]:
                engine._audio_queue.put(block)

            engine._drain_audio_blocks()
            engine._process_active_utterance(end_silence_threshold=1.0)

        self.assertEqual(callback.events, [("partial", 1, "rolled")])
        self.assertIn("reason=roll_silence", "\n".join(logs.output))
        self.assertIsNotNone(engine._utterance)

    def test_final_audio_trim_sends_full_audio_to_partial_and_trimmed_audio_to_final(self) -> None:
        config = AsrConfig(
            sample_rate=10,
            input_block_seconds=0.1,
            partial_interval_seconds=0.0,
            partial_min_audio_seconds=0.1,
            vad_start_speech_seconds=0.1,
            vad_min_utterance_seconds=0.1,
            filter_fillers=False,
            min_final_chars=1,
            final_audio_trim_enabled=True,
            final_trailing_silence_keep_seconds=0.0,
        )
        callback = _RecordingCallback()
        engine = PartialEngine(config, callback)
        engine._model = object()
        engine._active_threshold = 0.1
        engine.set_listening(True)

        stream_sample_counts: list[int] = []
        generate_sample_counts: list[int] = []

        def stream(_model, blocks, _config):
            stream_sample_counts.append(sum(len(block.samples) for block in blocks))
            return "hello partial"

        def generate(_model, blocks, _config):
            generate_sample_counts.append(sum(len(block.samples) for block in blocks))
            return "hello final"

        speech = np.full(1, 0.5, dtype=np.float32)
        silence = np.zeros(1, dtype=np.float32)

        with (
            patch("asr.partial_engine.stream_utterance_text", stream),
            patch("asr.partial_engine.generate_utterance_text", generate),
        ):
            for block in [
                AudioBlock(samples=speech, captured_at=0.0),
                AudioBlock(samples=speech, captured_at=0.1),
                AudioBlock(samples=silence, captured_at=0.2),
                AudioBlock(samples=silence, captured_at=0.3),
            ]:
                engine._audio_queue.put(block)

            engine._drain_audio_blocks()
            engine._process_active_utterance(end_silence_threshold=0.3)

            engine._audio_queue.put(AudioBlock(samples=silence, captured_at=0.4))
            engine._drain_audio_blocks()
            engine._process_active_utterance(end_silence_threshold=0.3)

        self.assertEqual(stream_sample_counts, [4])
        self.assertEqual(generate_sample_counts, [2])
        self.assertEqual(
            callback.events,
            [
                ("partial", 1, "hello partial"),
                ("final", 1, "hello final"),
            ],
        )

    def test_final_audio_trim_disabled_sends_full_audio_to_final(self) -> None:
        config = AsrConfig(
            sample_rate=10,
            final_audio_trim_enabled=False,
            filter_fillers=False,
            min_final_chars=1,
            vad_min_utterance_seconds=0.1,
        )
        callback = _RecordingCallback()
        engine = PartialEngine(config, callback)
        engine._model = object()
        utterance = partial_engine._UtteranceState(
            utterance_id=1,
            blocks=[
                AudioBlock(samples=np.ones(1, dtype=np.float32), captured_at=0.0),
                AudioBlock(samples=np.zeros(1, dtype=np.float32), captured_at=0.1),
            ],
            started_at=0.0,
            last_voice_at=0.0,
            speech_started_at=0.0,
            silence_run_seconds=0.1,
        )

        generate_sample_counts: list[int] = []

        def generate(_model, blocks, _config):
            generate_sample_counts.append(sum(len(block.samples) for block in blocks))
            return "ok"

        with patch("asr.partial_engine.generate_utterance_text", generate):
            engine._finalize_utterance(utterance)

        self.assertEqual(generate_sample_counts, [2])

    def test_soft_boundary_checkpoints_long_utterance_on_short_silence(self) -> None:
        config = AsrConfig(
            sample_rate=10,
            input_block_seconds=0.1,
            partial_min_audio_seconds=99.0,
            vad_start_speech_seconds=0.1,
            vad_end_silence_seconds=1.0,
            vad_min_utterance_seconds=0.1,
            vad_soft_max_utterance_seconds=0.3,
            vad_soft_break_silence_seconds=0.15,
            vad_max_utterance_seconds=5.0,
            filter_fillers=False,
            min_final_chars=1,
            final_audio_trim_enabled=False,
        )
        callback = _RecordingCallback()
        engine = PartialEngine(config, callback)
        engine._model = object()
        engine._active_threshold = 0.1
        engine.set_listening(True)

        speech = np.full(1, 0.5, dtype=np.float32)
        silence = np.zeros(1, dtype=np.float32)

        with (
            self.assertLogs("asr.partial_engine", level="INFO") as logs,
            patch("asr.partial_engine.generate_utterance_text", return_value="soft final"),
        ):
            for block in [
                AudioBlock(samples=speech, captured_at=0.0),
                AudioBlock(samples=speech, captured_at=0.1),
                AudioBlock(samples=speech, captured_at=0.2),
                AudioBlock(samples=silence, captured_at=0.3),
                AudioBlock(samples=silence, captured_at=0.4),
            ]:
                engine._audio_queue.put(block)

            engine._drain_audio_blocks()
            engine._process_active_utterance(end_silence_threshold=1.0)

        self.assertEqual(callback.events, [("partial", 1, "soft final")])
        self.assertIn("reason=soft_silence", "\n".join(logs.output))
        self.assertIsNotNone(engine._utterance)

    def test_soft_boundary_waits_until_soft_max_is_reached(self) -> None:
        config = AsrConfig(
            sample_rate=10,
            input_block_seconds=0.1,
            partial_min_audio_seconds=99.0,
            vad_start_speech_seconds=0.1,
            vad_end_silence_seconds=1.0,
            vad_min_utterance_seconds=0.1,
            vad_soft_max_utterance_seconds=1.0,
            vad_soft_break_silence_seconds=0.15,
            vad_max_utterance_seconds=5.0,
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

        with patch("asr.partial_engine.generate_utterance_text") as generate:
            for block in [
                AudioBlock(samples=speech, captured_at=0.0),
                AudioBlock(samples=speech, captured_at=0.1),
                AudioBlock(samples=speech, captured_at=0.2),
                AudioBlock(samples=silence, captured_at=0.3),
                AudioBlock(samples=silence, captured_at=0.4),
            ]:
                engine._audio_queue.put(block)

            engine._drain_audio_blocks()
            engine._process_active_utterance(end_silence_threshold=1.0)

        generate.assert_not_called()
        self.assertEqual(callback.events, [])
        self.assertIsNotNone(engine._utterance)


if __name__ == "__main__":
    unittest.main()
