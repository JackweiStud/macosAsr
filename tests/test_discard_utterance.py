from __future__ import annotations

from pathlib import Path
import threading
import unittest
from unittest.mock import patch

import numpy as np

from asr.asr_core import AudioBlock
from asr.config import AsrConfig
from asr.partial_engine import PartialEngine
from asr_daemon.server import DaemonServer, _CallbackBridge
from asr_daemon.session import SessionController


class _RecordingCallback:
    def __init__(self) -> None:
        self.events: list[tuple[str, int, str, float]] = []

    def on_partial(self, uid: int, text: str, utterance_started_at: float) -> None:
        self.events.append(("partial", uid, text, utterance_started_at))

    def on_final(self, uid: int, text: str, utterance_started_at: float) -> None:
        self.events.append(("final", uid, text, utterance_started_at))

    def on_filtered(self, uid: int, text: str, reason: str, utterance_started_at: float) -> None:
        self.events.append(("filtered", uid, reason, utterance_started_at))

    def on_error(self, message: str) -> None:
        raise AssertionError(message)

    def on_warning(self, message: str, code: str) -> None:
        pass


def _engine(callback=None) -> PartialEngine:
    config = AsrConfig(
        sample_rate=10,
        input_block_seconds=0.1,
        vad_pre_roll_seconds=0.5,
        vad_start_speech_seconds=0.2,
        vad_min_utterance_seconds=0.1,
        partial_interval_seconds=0.0,
        partial_min_audio_seconds=0.1,
        partial_max_audio_seconds=0.0,
        vad_soft_max_utterance_seconds=0.0,
        vad_max_utterance_seconds=0.0,
        filter_fillers=False,
        min_final_chars=1,
        final_audio_trim_enabled=False,
    )
    engine = PartialEngine(config, callback or _RecordingCallback())
    engine._model = object()
    engine._active_threshold = 0.1
    engine._clock_offset = lambda: 1000.0
    engine._configure_pre_roll()
    engine.set_listening(True)
    return engine


def _queue(engine: PartialEngine, *frames: tuple[float, bool]) -> None:
    for captured_at, voiced in frames:
        engine._audio_queue.put(AudioBlock(
            samples=np.full(1, 0.5 if voiced else 0.0, dtype=np.float32),
            captured_at=captured_at,
        ))


class DiscardUtteranceEngineTests(unittest.TestCase):
    def test_result_time_is_first_continuous_voice_block_and_excludes_pre_roll(self) -> None:
        callback = _RecordingCallback()
        engine = _engine(callback)
        _queue(engine, (9.8, False), (9.9, True), (10.0, False), (10.1, True), (10.2, True))
        engine._drain_audio_blocks()
        self.assertEqual(engine._utterance.started_at, 9.8)
        self.assertEqual(engine._utterance.speech_started_at, 10.1)

        with patch("asr.partial_engine.stream_utterance_text", return_value="new words"):
            engine._process_active_utterance(1.0)
        _queue(engine, (10.3, False))
        engine._drain_audio_blocks()
        with patch("asr.partial_engine.generate_utterance_text", return_value="final words"):
            engine._process_active_utterance(0.1)

        self.assertEqual(callback.events, [
            ("partial", 1, "new words", 1010.1),
            ("final", 1, "final words", 1010.1),
        ])

    def test_discard_after_partial_is_queued_and_keeps_listening_and_mic(self) -> None:
        callback = _RecordingCallback()
        engine = _engine(callback)
        engine._stream = object()
        stream = engine._stream
        _queue(engine, (1.0, True), (1.1, True))
        engine._drain_audio_blocks()
        with patch("asr.partial_engine.stream_utterance_text", return_value="already sent"):
            engine._process_active_utterance(1.0)
        old = engine._utterance

        engine.discard_utterance(1002.0)
        self.assertIs(engine._utterance, old)  # Client thread only enqueues work.
        engine._drain_control_queue()

        self.assertIsNone(engine._utterance)
        self.assertTrue(engine.is_listening())
        self.assertIs(engine._stream, stream)
        self.assertEqual(callback.events, [("partial", 1, "already sent", 1001.0)])

        _queue(engine, (1.9, True), (2.0, True), (2.1, True), (2.2, True))
        engine._drain_audio_blocks()
        with patch("asr.partial_engine.stream_utterance_text", return_value="next sentence"):
            engine._process_active_utterance(1.0)
        self.assertEqual(callback.events[-1], ("partial", 2, "next sentence", 1002.1))
        self.assertEqual([b.captured_at for b in engine._utterance.blocks], [2.1, 2.2])

    def test_clock_offset_changes_keep_sentence_identity_and_use_current_discard_time(self) -> None:
        callback = _RecordingCallback()
        engine = _engine(callback)
        _queue(engine, (1.0, True), (1.1, True))
        engine._drain_audio_blocks()
        with patch("asr.partial_engine.stream_utterance_text", return_value="old words"):
            engine._process_active_utterance(1.0)

        engine._clock_offset = lambda: 1600.0
        _queue(engine, (1.2, False))
        engine._drain_audio_blocks()
        with patch("asr.partial_engine.generate_utterance_text", return_value="old final"):
            engine._process_active_utterance(0.1)
        self.assertEqual([event[3] for event in callback.events], [1001.0, 1001.0])

        engine.discard_utterance(1602.0)
        engine._drain_control_queue()
        _queue(engine, (1.9, True), (2.1, True), (2.2, True))
        engine._drain_audio_blocks()
        with patch("asr.partial_engine.stream_utterance_text", return_value="new words"):
            engine._process_active_utterance(1.0)
        self.assertEqual(engine._discard_before, 2.0)
        self.assertEqual(callback.events[-1], ("partial", 2, "new words", 1602.1))

    def test_discard_before_any_partial_prevents_old_utterance_from_finalizing(self) -> None:
        callback = _RecordingCallback()
        engine = _engine(callback)
        _queue(engine, (1.0, True), (1.1, True))
        engine._drain_audio_blocks()
        engine.discard_utterance(1002.0)
        engine._drain_control_queue()
        _queue(engine, (1.2, True), (2.0, False))
        engine._drain_audio_blocks()

        with patch("asr.partial_engine.generate_utterance_text") as generate:
            engine._process_active_utterance(0.1)
        generate.assert_not_called()
        self.assertEqual(callback.events, [])
        self.assertIsNone(engine._utterance)

    def test_new_voice_with_old_pre_roll_is_preserved_after_delayed_discard(self) -> None:
        engine = _engine()
        _queue(engine, (9.8, False), (9.9, False), (10.1, True), (10.2, True))
        engine._drain_audio_blocks()
        utterance = engine._utterance
        self.assertLess(utterance.started_at, 10.0)

        engine.discard_utterance(1010.0)
        engine._drain_control_queue()

        self.assertIs(engine._utterance, utterance)
        self.assertEqual(utterance.speech_started_at, 10.1)
        self.assertEqual([b.captured_at for b in utterance.blocks], [10.1, 10.2])

    def test_post_click_audio_already_in_old_utterance_is_replayed_before_queued_frames(self) -> None:
        engine = _engine()
        _queue(engine, (1.0, True), (1.1, True), (2.1, True), (2.2, True))
        engine._drain_audio_blocks()
        self.assertEqual(engine._utterance.utterance_id, 1)
        _queue(engine, (2.3, True))

        engine.discard_utterance(1002.0)
        engine._drain_control_queue()
        engine._drain_audio_blocks()

        self.assertEqual(engine._utterance.utterance_id, 2)
        self.assertEqual(engine._utterance.speech_started_at, 2.1)
        self.assertEqual([b.captured_at for b in engine._utterance.blocks], [2.1, 2.2, 2.3])

    def test_discard_resets_provisional_voice_and_preserves_post_click_run(self) -> None:
        engine = _engine()
        engine._config.vad_start_speech_seconds = 0.3
        _queue(engine, (1.9, True), (2.1, True))
        engine._drain_audio_blocks()
        self.assertIsNone(engine._utterance)
        engine.discard_utterance(1002.0)
        engine._drain_control_queue()
        _queue(engine, (2.2, True), (2.3, True))
        engine._drain_audio_blocks()

        self.assertEqual(engine._utterance.speech_started_at, 2.1)
        self.assertEqual([b.captured_at for b in engine._utterance.blocks], [2.1, 2.2, 2.3])

    def test_repeated_or_older_discard_never_moves_cutoff_backwards(self) -> None:
        engine = _engine()
        engine.discard_utterance(1010.0)
        engine.discard_utterance(1009.0)
        engine.discard_utterance(1010.0)
        engine._drain_control_queue()
        _queue(engine, (9.9, True), (10.0, True), (10.1, True), (10.2, True))
        engine._drain_audio_blocks()
        utterance = engine._utterance
        engine.discard_utterance(1009.5)
        engine._drain_control_queue()

        self.assertEqual(engine._discard_before, 10.0)
        self.assertIs(engine._utterance, utterance)
        self.assertEqual(utterance.speech_started_at, 10.1)

    def test_inflight_final_keeps_original_time_even_after_utterance_is_released(self) -> None:
        callback = _RecordingCallback()
        engine = _engine(callback)
        _queue(engine, (1.0, True), (1.1, True), (1.2, False))
        engine._drain_audio_blocks()
        inference_started = threading.Event()
        resume = threading.Event()

        def generate(*_):
            inference_started.set()
            self.assertTrue(resume.wait(2.0))
            return "late final"

        with patch("asr.partial_engine.generate_utterance_text", side_effect=generate):
            worker = threading.Thread(target=engine._process_active_utterance, args=(0.1,))
            worker.start()
            try:
                self.assertTrue(inference_started.wait(2.0))
                self.assertIsNone(engine._utterance)
                engine.discard_utterance(1002.0)
                _queue(engine, (2.1, True), (2.2, True))
            finally:
                resume.set()
                worker.join(2.0)
        self.assertFalse(worker.is_alive())
        self.assertEqual(callback.events, [("final", 1, "late final", 1001.0)])
        engine._drain_control_queue()
        engine._drain_audio_blocks()
        self.assertEqual(engine._utterance.speech_started_at, 2.1)

    def test_filtered_results_also_keep_real_voice_start(self) -> None:
        callback = _RecordingCallback()
        engine = _engine(callback)
        _queue(engine, (0.8, False), (1.0, True), (1.1, True), (1.2, False))
        engine._drain_audio_blocks()
        with patch("asr.partial_engine.generate_utterance_text", return_value=""):
            engine._process_active_utterance(0.1)
        self.assertEqual(callback.events, [("filtered", 1, "empty", 1001.0)])


class DiscardUtteranceIPCTests(unittest.TestCase):
    def setUp(self) -> None:
        bridge = _CallbackBridge()
        self.engine = _engine(bridge)
        self.events: list[dict] = []
        self.session = SessionController(self.engine, self.engine._config, self.events.append)
        bridge.bind(self.session)
        self.server = DaemonServer(Path("/tmp/macosasr-discard-test.sock"), self.engine._config, skip_model=True)
        self.server._engine = self.engine
        self.server._session = self.session
        with patch.object(self.engine, "_open_mic_stream"):
            self.sid = self.session.start_session()

    def _dispatch(self, **values) -> list[dict]:
        return self.server._dispatch({
            "protocol": 1, "cmd": "discard_utterance", "session_id": self.sid,
            "before": 1002.0, **values,
        })

    def test_command_acknowledges_queued_work_without_changing_session(self) -> None:
        _queue(self.engine, (1.0, True), (1.1, True))
        self.engine._drain_audio_blocks()
        old = self.engine._utterance
        self.assertEqual(self._dispatch(), [{
            "protocol": 1, "type": "utterance_discarded", "session_id": self.sid, "before": 1002.0,
            "discarded": True,
        }])
        self.assertIs(self.engine._utterance, old)
        self.assertEqual(self.session.session_id, self.sid)
        self.assertTrue(self.engine.is_listening())
        self.engine._drain_control_queue()
        self.assertIsNone(self.engine._utterance)

    def test_old_or_absent_session_is_ignored_without_failing_active_dictation(self) -> None:
        for session_id in ["s-old", None, "", 123]:
            with self.subTest(session_id=session_id):
                response = self._dispatch(session_id=session_id)[0]
                self.assertEqual(response["type"], "utterance_discarded")
                self.assertFalse(response["discarded"])
                self.assertEqual(self.session.session_id, self.sid)
                self.assertTrue(self.engine.is_listening())
        self.session._session_id = None
        self.assertFalse(self._dispatch()[0]["discarded"])
        self.assertTrue(self.engine._control_queue.empty())

    def test_session_identity_is_announced_before_recognition_can_emit(self) -> None:
        self.session._session_id = None
        self.events.clear()
        original_set_listening = self.engine.set_listening

        def enable_and_emit(listening):
            original_set_listening(listening)
            if listening:
                self.session.on_partial(1, "first words", 1001.0)

        with (
            patch.object(self.engine, "_open_mic_stream"),
            patch.object(self.engine, "set_listening", side_effect=enable_and_emit),
        ):
            sid = self.session.start_session()

        self.assertEqual([event["type"] for event in self.events], ["session_started", "partial"])
        self.assertTrue(all(event["session_id"] == sid for event in self.events))

    def test_nonfinite_or_nonnumeric_cutoffs_are_rejected(self) -> None:
        for before in [None, "1002", True, float("nan"), float("inf"), -float("inf"), 10 ** 1000]:
            with self.subTest(before=before):
                self.assertEqual(self._dispatch(before=before)[0]["code"], "invalid_before")
        self.assertTrue(self.engine._control_queue.empty())

    def test_real_engine_bridge_session_results_all_include_same_voice_start(self) -> None:
        _queue(self.engine, (0.8, False), (1.0, True), (1.1, True))
        self.engine._drain_audio_blocks()
        with patch("asr.partial_engine.stream_utterance_text", return_value="partial"):
            self.engine._process_active_utterance(1.0)
        _queue(self.engine, (1.2, False))
        self.engine._drain_audio_blocks()
        with patch("asr.partial_engine.generate_utterance_text", return_value="final"):
            self.engine._process_active_utterance(0.1)
        _queue(self.engine, (2.0, True), (2.1, True), (2.2, False))
        self.engine._drain_audio_blocks()
        with patch("asr.partial_engine.generate_utterance_text", return_value=""):
            self.engine._process_active_utterance(0.1)

        results = [event for event in self.events if event["type"] in {"partial", "final", "filtered"}]
        self.assertEqual([event["type"] for event in results], ["partial", "final", "filtered"])
        self.assertEqual([event["utterance_started_at"] for event in results], [1001.0, 1001.0, 1002.0])
        self.assertTrue(all(event["session_id"] == self.sid for event in results))
        self.assertEqual([event["utterance_id"] for event in results], [1, 1, 2])

    def test_normal_stop_still_flushes_tail_before_session_stopped(self) -> None:
        _queue(self.engine, (1.0, True), (1.1, True))
        self.engine._drain_audio_blocks()
        with patch("asr.partial_engine.generate_utterance_text", return_value="tail words"):
            stop = threading.Thread(target=self.session.stop_session)
            stop.start()
            command = self.engine._control_queue.get(timeout=2.0)
            self.engine._control_queue.put(command)
            self.engine._drain_control_queue()
            stop.join(2.0)
        self.assertFalse(stop.is_alive())
        self.assertEqual([event["type"] for event in self.events], ["session_started", "final", "session_stopped"])
        self.assertEqual(self.events[1]["text"], "tail words")
        self.assertEqual(self.events[1]["utterance_started_at"], 1001.0)
        self.assertIsNone(self.session.session_id)


if __name__ == "__main__":
    unittest.main()
