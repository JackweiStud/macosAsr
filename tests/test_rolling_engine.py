from __future__ import annotations

import threading
import unittest
from unittest.mock import patch

import numpy as np

from asr.asr_core import AudioBlock
from asr.config import AsrConfig
from asr.partial_engine import PartialEngine, _UtteranceState


class _Callback:
    def __init__(self) -> None:
        self.events: list[tuple[str, int, str, float]] = []
        self.warnings: list[str] = []

    def on_partial(self, uid: int, text: str, started: float) -> None:
        self.events.append(("partial", uid, text, started))

    def on_final(self, uid: int, text: str, started: float) -> None:
        self.events.append(("final", uid, text, started))

    def on_filtered(self, uid: int, text: str, reason: str, started: float) -> None:
        self.events.append(("filtered", uid, reason, started))

    def on_warning(self, message: str, code: str) -> None:
        self.warnings.append(code)

    def on_error(self, message: str) -> None:
        raise AssertionError(message)


def _blocks(start: float, count: int, voiced: bool = True) -> list[AudioBlock]:
    return [AudioBlock(np.full(1, 0.5 if voiced else 0.0, dtype=np.float32), start + i / 10)
            for i in range(count)]


def _engine(active: bool = True, **overrides) -> tuple[PartialEngine, _Callback]:
    settings = dict(
        sample_rate=10, input_block_seconds=0.1,
        partial_interval_seconds=0.0, partial_min_audio_seconds=0.1,
        partial_max_audio_seconds=1.0, partial_roll_min_seconds=1.0,
        rolling_overlap_seconds=0.4, rolling_max_audio_seconds=2.0,
        rolling_retry_audio_seconds=0.3,
        vad_start_speech_seconds=0.1, vad_pre_roll_seconds=0.1,
        vad_end_silence_seconds=0.3, vad_min_utterance_seconds=0.1,
        vad_soft_max_utterance_seconds=0.0, vad_max_utterance_seconds=0.0,
        final_audio_trim_enabled=False, filter_fillers=False, min_final_chars=1,
    )
    settings.update(overrides)
    callback = _Callback()
    engine = PartialEngine(AsrConfig(**settings), callback)
    engine._model = object()
    engine._active_threshold = 0.1
    engine._clock_offset = lambda: 1000.0
    engine._configure_pre_roll()
    engine.set_listening(True)
    if active:
        engine._utterance_id = 7
        engine._utterance = _UtteranceState(
            utterance_id=7, blocks=_blocks(10.0, 10),
            started_at=10.0, last_voice_at=10.9, speech_started_at=10.0,
            speech_started_at_unix=1010.0, audio_seconds=1.0,
        )
    return engine, callback


class RollingEngineTests(unittest.TestCase):
    def test_window_boundary_punctuation_remains_revisable_with_same_identity(self) -> None:
        engine, callback = _engine()
        utterance = engine._utterance
        with patch("asr.partial_engine.generate_utterance_text", side_effect=["前面这个。", "这个。", "前面"]):
            engine._process_active_utterance(0.3)

        self.assertIs(engine._utterance, utterance)
        self.assertLess(engine._audio_seconds(utterance.blocks), 1.0)
        self.assertEqual(utterance.transcript.committed, "前面")
        self.assertEqual(callback.events, [("partial", 7, "前面这个。", 1010.0)])

        with patch("asr.partial_engine.stream_utterance_text", return_value="这个是什么问题？"):
            engine._process_active_utterance(0.3)
        utterance.silence_run_seconds = 0.3
        with patch("asr.partial_engine.generate_utterance_text", return_value="这个是什么问题？"):
            engine._process_active_utterance(0.3)

        self.assertEqual(callback.events[-2:], [
            ("partial", 7, "前面这个是什么问题？", 1010.0),
            ("final", 7, "前面这个是什么问题？", 1010.0),
        ])
        self.assertIsNone(engine._utterance)

    def test_multiple_windows_preserve_real_repetition_without_extra_overlap(self) -> None:
        engine, callback = _engine()
        utterance = engine._utterance
        with patch("asr.partial_engine.generate_utterance_text", side_effect=["第一次窗口，窗口中", "窗口中", "第一次窗口，"]):
            engine._process_active_utterance(0.3)
        utterance.blocks.extend(_blocks(11.0, 6))
        utterance.audio_seconds += 0.6
        with patch("asr.partial_engine.generate_utterance_text", side_effect=["窗口中继续，窗口中", "窗口中", "窗口中继续，"]):
            engine._process_active_utterance(0.3)
        utterance.silence_run_seconds = 0.3
        with patch("asr.partial_engine.generate_utterance_text", return_value="窗口中结束。"):
            engine._process_active_utterance(0.3)

        self.assertEqual(callback.events[-1], ("final", 7, "第一次窗口，窗口中继续，窗口中结束。", 1010.0))
        self.assertEqual([e[0] for e in callback.events], ["partial", "partial", "final"])

    def test_rejected_alignment_requires_new_audio_before_retry(self) -> None:
        engine, callback = _engine()
        utterance = engine._utterance
        with (
            patch("asr.partial_engine.generate_utterance_text", side_effect=[
                "仍可见的正文", "不匹配", "仍可见的", "仍可见的正文", "不匹配", "仍可见的",
            ]) as generate,
            patch("asr.partial_engine.stream_utterance_text", return_value="仍可见的正文"),
        ):
            engine._process_active_utterance(0.3)
            self.assertEqual(generate.call_count, 3)
            original_blocks = list(utterance.blocks)
            engine._process_active_utterance(0.3)
            self.assertEqual(generate.call_count, 3)
            utterance.blocks.extend(_blocks(11.0, 2))
            engine._process_active_utterance(0.3)
            self.assertEqual(generate.call_count, 3)
            utterance.blocks.extend(_blocks(11.2, 1))
            engine._process_active_utterance(0.3)
            self.assertEqual(generate.call_count, 6)
        self.assertEqual(utterance.blocks[:10], original_blocks)
        self.assertEqual(utterance.transcript.text, "仍可见的正文")
        self.assertEqual(callback.warnings, [])
        self.assertTrue(all(e[0] == "partial" for e in callback.events))

    def test_truncated_overlap_rejects_checkpoint_until_audio_coverage_agrees(self) -> None:
        engine, callback = _engine()
        utterance = engine._utterance
        original_blocks = list(utterance.blocks)
        decoded_blocks: list[list[AudioBlock]] = []
        answers = iter([
            "前面继续讨论这个问题", "问题", "前面",
            "前面继续讨论这个问题我们", "这个问题我们", "前面继续讨论",
        ])

        def generate(_model, blocks, _config):
            decoded_blocks.append(list(blocks))
            return next(answers)

        with patch("asr.partial_engine.generate_utterance_text", side_effect=generate):
            engine._process_active_utterance(0.3)
            # The tail still matches the full hypothesis, but its decode has
            # omitted words that the outgoing-audio decode does not contain.
            self.assertEqual(utterance.blocks, original_blocks)
            self.assertEqual(utterance.transcript.committed, "")
            self.assertEqual(utterance.transcript.last_error, "audio_cut_coverage_mismatch")
            self.assertEqual(utterance.last_checkpoint_audio_seconds, 1.0)
            self.assertEqual(decoded_blocks[2] + decoded_blocks[1], original_blocks)

            new_blocks = _blocks(11.0, 3)
            utterance.blocks.extend(new_blocks)
            utterance.audio_seconds += 0.3
            engine._process_active_utterance(0.3)

        self.assertLess(len(utterance.blocks), len(original_blocks) + len(new_blocks))
        self.assertEqual(utterance.transcript.committed, "前面继续讨论")
        self.assertEqual(utterance.transcript.text, "前面继续讨论这个问题我们")
        self.assertEqual(decoded_blocks[5] + decoded_blocks[4], original_blocks + new_blocks)
        self.assertEqual([event[0] for event in callback.events], ["partial", "partial"])
        self.assertTrue(all(event[1] == 7 for event in callback.events))
        self.assertEqual(callback.warnings, [])

    def test_real_audio_backlog_stays_bounded_even_when_alignment_never_succeeds(self) -> None:
        engine, callback = _engine(active=False)
        # One deliberately oversized queued block also exercises splitting into
        # capture frames; draining the queue must not grow a 10-second window.
        engine._audio_queue.put(AudioBlock(np.full(100, 0.5, dtype=np.float32), 0.0))
        maximum = 0.0
        decode_lengths: list[float] = []

        def generate(_model, blocks, _config):
            decode_lengths.append(engine._audio_seconds(blocks))
            return "连续讲话" if len(decode_lengths) % 3 == 1 else "无法对齐"

        with patch("asr.partial_engine.generate_utterance_text", side_effect=generate):
            for _ in range(200):
                engine._drain_audio_blocks()
                if engine._utterance is not None:
                    maximum = max(maximum, engine._audio_seconds(engine._utterance.blocks))
                engine._process_active_utterance(0.3)
                if engine._audio_queue.empty() and not engine._pending_audio_blocks:
                    break
            else:
                self.fail("audio backlog did not make progress")

        self.assertLessEqual(maximum, 2.0 + engine._config.input_block_seconds + 1e-9)
        self.assertLessEqual(max(decode_lengths), 2.0 + engine._config.input_block_seconds + 1e-9)
        self.assertTrue(callback.warnings)
        self.assertEqual(set(callback.warnings), {"rolling_alignment_fallback"})
        self.assertTrue(all(e[0] == "partial" for e in callback.events))
        self.assertEqual(engine._utterance.utterance_id, 1)
        self.assertEqual(engine._utterance.speech_started_at_unix, 1000.0)

    def test_stop_flush_drains_multiple_windows_without_losing_captured_tail(self) -> None:
        engine, callback = _engine(active=False)
        alphabet = "甲乙丙丁戊己庚辛壬癸天地玄黄宇宙洪荒日月盈昃辰宿列张寒来暑往秋收冬藏闰余成岁律吕调阳"
        for block in _blocks(0.0, 35):
            engine._audio_queue.put(block)
        engine._drain_audio_blocks()
        self.assertFalse(engine._audio_queue.empty())
        with patch("asr.partial_engine.time.perf_counter", return_value=3.45):
            engine.set_listening(False)

        decoded_seconds: list[float] = []

        def generate(_model, blocks, _config):
            decoded_seconds.append(engine._audio_seconds(blocks))
            return "".join(alphabet[round(block.captured_at * 10)] for block in blocks)

        with patch("asr.partial_engine.generate_utterance_text", side_effect=generate):
            stop = threading.Thread(target=engine.flush_on_stop)
            stop.start()
            command = engine._control_queue.get(timeout=2.0)
            self.assertEqual(command.before, 3.45)
            engine._control_queue.put(command)
            engine._drain_control_queue()
            stop.join(2.0)

        self.assertFalse(stop.is_alive())
        self.assertEqual([event for event in callback.events if event[0] == "final"], [
            ("final", 1, alphabet[:35], 1000.0),
        ])
        self.assertTrue(all(event[1] == 1 and event[3] == 1000.0 for event in callback.events))
        self.assertGreater(len(decoded_seconds), 2)
        self.assertLessEqual(max(decoded_seconds), 2.0 + engine._config.input_block_seconds)
        self.assertTrue(engine._audio_queue.empty())
        self.assertIsNone(engine._utterance)

    def test_stop_barrier_preserves_gap_backlog_and_excludes_later_audio(self) -> None:
        engine, callback = _engine(active=False)
        alphabet = "甲乙丙丁戊己庚辛壬癸天地玄黄宇宙洪荒日月盈昃辰宿列张"
        for block in _blocks(0.0, 15):
            engine._audio_queue.put(block)
        with patch("asr.partial_engine.time.perf_counter", return_value=1.45):
            engine.set_listening(False)
        # A worker iteration can fall between set_listening(False) and flush.
        # It must leave the captured tail intact for the worker barrier.
        engine._drain_audio_blocks()
        self.assertEqual(engine._audio_queue.qsize(), 15)
        for block in _blocks(1.5, 5):
            engine._audio_queue.put(block)

        def generate(_model, blocks, _config):
            self.assertTrue(all(block.captured_at <= 1.45 for block in blocks))
            return "".join(alphabet[round(block.captured_at * 10)] for block in blocks)

        with patch("asr.partial_engine.generate_utterance_text", side_effect=generate):
            stop = threading.Thread(target=engine.flush_on_stop)
            stop.start()
            command = engine._control_queue.get(timeout=2.0)
            # Use stop time, not this later flush call's wall clock.
            self.assertEqual(command.before, 1.45)
            engine._control_queue.put(command)
            engine._drain_control_queue()
            stop.join(2.0)

        self.assertFalse(stop.is_alive())
        self.assertEqual(callback.events[-1], ("final", 1, alphabet[:15], 1000.0))
        self.assertEqual(engine._pending_audio_blocks[0].captured_at, 1.5)
        self.assertEqual(engine._audio_queue.qsize(), 4)

    def test_stop_racing_with_dequeue_requeues_frame_for_flush(self) -> None:
        engine, _ = _engine(active=False)
        block = _blocks(0.0, 1)[0]
        engine._audio_queue.put(block)

        def rms_and_stop(_samples):
            engine.set_listening(False)
            return 0.5

        with patch("asr.partial_engine.audio_rms", side_effect=rms_and_stop):
            engine._drain_audio_blocks()

        self.assertEqual(list(engine._pending_audio_blocks), [block])
        self.assertIsNone(engine._utterance)

    def test_discard_queued_before_stop_cancels_old_active_and_backlog(self) -> None:
        engine, callback = _engine()
        for block in _blocks(11.0, 10):
            engine._audio_queue.put(block)
        engine.discard_utterance(1012.0)
        with patch("asr.partial_engine.time.perf_counter", return_value=12.0):
            engine.set_listening(False)
        with patch("asr.partial_engine.generate_utterance_text") as generate:
            stop = threading.Thread(target=engine.flush_on_stop)
            stop.start()
            # The discard remains before the flush on the worker queue.
            first = engine._control_queue.get(timeout=2.0)
            second = engine._control_queue.get(timeout=2.0)
            engine._control_queue.put(first)
            engine._control_queue.put(second)
            engine._drain_control_queue()
            stop.join(2.0)

        self.assertFalse(stop.is_alive())
        generate.assert_not_called()
        self.assertEqual(callback.events, [])
        self.assertIsNone(engine._utterance)

    def test_hard_fallback_then_silence_or_stop_preserves_text_without_decoding_silence(self) -> None:
        for stop in [False, True]:
            with self.subTest(stop=stop):
                engine, callback = _engine()
                utterance = engine._utterance
                utterance.blocks.extend(_blocks(11.0, 10))
                with patch("asr.partial_engine.generate_utterance_text", side_effect=["已经显示的正文", "不匹配", "已经显示的"]):
                    engine._process_active_utterance(0.3)
                self.assertEqual(utterance.blocks, [])
                self.assertEqual(utterance.transcript.committed, "已经显示的正文")
                for block in _blocks(12.0, 3, voiced=False):
                    engine._audio_queue.put(block)
                engine._drain_audio_blocks()
                with patch("asr.partial_engine.generate_utterance_text") as generate:
                    if stop:
                        done = threading.Event()
                        engine._control_queue.put(("flush", done))
                        engine._drain_control_queue()
                        self.assertTrue(done.is_set())
                    else:
                        engine._process_active_utterance(0.3)
                generate.assert_not_called()
                self.assertEqual(callback.events[-1], ("final", 7, "已经显示的正文", 1010.0))
                self.assertIsNone(engine._utterance)

    def test_discard_after_checkpoint_drops_old_sentence_and_accepts_next_voice(self) -> None:
        engine, callback = _engine()
        with patch("asr.partial_engine.generate_utterance_text", side_effect=["之前这个。", "这个。", "之前"]):
            engine._process_active_utterance(0.3)
        engine.discard_utterance(1011.0)
        engine._drain_control_queue()
        for block in _blocks(11.1, 2):
            engine._audio_queue.put(block)
        engine._drain_audio_blocks()
        with patch("asr.partial_engine.stream_utterance_text", return_value="下一句话"):
            engine._process_active_utterance(0.3)
        self.assertEqual(callback.events[-1], ("partial", 8, "下一句话", 1011.1))
        self.assertEqual(callback.events[0], ("partial", 7, "之前这个。", 1010.0))


if __name__ == "__main__":
    unittest.main()
