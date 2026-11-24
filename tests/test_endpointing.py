from __future__ import annotations

import unittest
from unittest.mock import patch

import numpy as np

from asr.asr_core import AudioBlock
from asr.config import AsrConfig
from asr.endpointing import compute_end_silence_threshold
from asr.partial_engine import PartialEngine


class _Callback:
    def __init__(self) -> None:
        self.events: list[tuple[str, int, str]] = []

    def on_partial(self, uid: int, text: str, _started: float) -> None:
        self.events.append(("partial", uid, text))

    def on_final(self, uid: int, text: str, _started: float) -> None:
        self.events.append(("final", uid, text))

    def on_filtered(self, uid: int, text: str, reason: str, _started: float) -> None:
        self.events.append(("filtered", uid, reason))

    def on_warning(self, message: str, code: str) -> None:
        pass

    def on_error(self, message: str) -> None:
        raise AssertionError(message)


class SemanticEndpointingUnitTests(unittest.TestCase):
    def setUp(self) -> None:
        self.cfg = AsrConfig(
            vad_end_silence_seconds=2.0,
            semantic_endpointing_enabled=True,
            semantic_fast_silence_ratio=0.50,
            semantic_fast_question_ratio=0.45,
            semantic_fast_min_silence_seconds=0.80,
        )

    def test_closed_declarative_and_question_use_fast_channel(self) -> None:
        dec = compute_end_silence_threshold(
            2.0,
            "然后启动 FastAPI 服务连接 PostgreSQL 数据库。",
            partial_fresh=True,
            config=self.cfg,
        )
        self.assertEqual(dec.mode, "fast_close")
        self.assertAlmostEqual(dec.threshold_seconds, 1.0)

        q = compute_end_silence_threshold(
            2.0,
            "这两项修改达到了如此好的效果吗？",
            partial_fresh=True,
            config=self.cfg,
        )
        self.assertEqual(q.mode, "fast_question")
        self.assertAlmostEqual(q.threshold_seconds, 0.9)

        short_ok = compute_end_silence_threshold(
            2.0,
            "没问题。",
            partial_fresh=True,
            config=self.cfg,
        )
        self.assertEqual(short_ok.mode, "fast_close")
        self.assertAlmostEqual(short_ok.threshold_seconds, 1.0)

        pred_de = compute_end_silence_threshold(
            2.0,
            "感觉还是非常挺不错的。",
            partial_fresh=True,
            config=self.cfg,
        )
        self.assertEqual(pred_de.mode, "fast_close")

    def test_dangling_conjunctions_fragments_and_mid_thought_stay_on_full_wait(self) -> None:
        cases = [
            "我们使用。",
            "我们使用 git commit 提交一个 pull request，然后。",
            "已经识别出了五个。",
            "然后针对的这个问题点，是不是已经。",
            "现在你在逐渐的一个个的修改，完成以后，",
            "刚才说的那个关于。",
            "我们正在优化的。",
            "Let us connect to the.",
            "打开这个（括号还没关。",
            "等一下……",
        ]
        for text in cases:
            with self.subTest(text=text):
                dec = compute_end_silence_threshold(2.0, text, partial_fresh=True, config=self.cfg)
                self.assertEqual(dec.mode, "full_wait")
                self.assertAlmostEqual(dec.threshold_seconds, 2.0)

    def test_stale_partial_never_fast_closes(self) -> None:
        dec = compute_end_silence_threshold(
            2.0,
            "这一句已经说完了。",
            partial_fresh=False,
            config=self.cfg,
        )
        self.assertEqual(dec.mode, "full_wait")
        self.assertEqual(dec.reason, "stale_or_empty_partial")

    def test_disabled_or_already_quick_base_preserves_base_threshold(self) -> None:
        disabled_cfg = AsrConfig(semantic_endpointing_enabled=False)
        dec = compute_end_silence_threshold(2.0, "已经说完了。", partial_fresh=True, config=disabled_cfg)
        self.assertEqual(dec.mode, "disabled")
        self.assertAlmostEqual(dec.threshold_seconds, 2.0)

        quick = compute_end_silence_threshold(0.6, "已经说完了。", partial_fresh=True, config=self.cfg)
        self.assertEqual(quick.mode, "full_wait")
        self.assertAlmostEqual(quick.threshold_seconds, 0.6)


class PartialEngineSemanticEndpointingTests(unittest.TestCase):
    def _make_engine(self) -> tuple[PartialEngine, _Callback]:
        cb = _Callback()
        cfg = AsrConfig(
            sample_rate=10,
            input_block_seconds=0.1,
            partial_interval_seconds=0.0,
            partial_min_audio_seconds=0.1,
            partial_max_audio_seconds=0.0,
            vad_start_speech_seconds=0.1,
            vad_min_utterance_seconds=0.1,
            vad_pre_roll_seconds=0.1,
            vad_end_silence_seconds=2.0,
            vad_soft_max_utterance_seconds=0.0,
            vad_max_utterance_seconds=0.0,
            final_audio_trim_enabled=False,
            filter_fillers=False,
            min_final_chars=1,
            semantic_endpointing_enabled=True,
            semantic_fast_silence_ratio=0.50,
            semantic_fast_min_silence_seconds=0.80,
        )
        engine = PartialEngine(cfg, cb)
        engine._model = object()
        engine._active_threshold = 0.1
        engine._calibrated = True
        engine._measured_noise_floor = 0.03
        engine._configure_pre_roll()
        engine.set_listening(True)
        return engine, cb

    def test_closed_sentence_finalizes_at_fast_threshold_while_dangling_holds_full_wait(self) -> None:
        engine, cb = self._make_engine()
        speech = np.full(1, 0.5, dtype=np.float32)
        silence = np.zeros(1, dtype=np.float32)

        # Feed 0.3s speech + 0.5s silence, emit fresh partial with dangling conjunction.
        for i in range(3):
            engine._audio_queue.put(AudioBlock(speech, i * 0.1))
        for i in range(3, 8):
            engine._audio_queue.put(AudioBlock(silence, i * 0.1))
        engine._drain_audio_blocks()
        with patch("asr.partial_engine.stream_utterance_text", return_value="我们接着看这个问题，然后。"):
            engine._process_active_utterance(2.0)

        # Reach 1.0s silence -> must NOT finalize because partial ends in dangling "然后。".
        for i in range(8, 13):
            engine._audio_queue.put(AudioBlock(silence, i * 0.1))
        engine._drain_audio_blocks()
        with (
            patch("asr.partial_engine.stream_utterance_text", return_value="我们接着看这个问题，然后。"),
            patch("asr.partial_engine.generate_utterance_text") as gen,
        ):
            engine._process_active_utterance(2.0)
            gen.assert_not_called()
        self.assertIsNotNone(engine._utterance)

        # Speaker continues and finishes sentence cleanly; fresh partial sees complete declarative.
        engine._audio_queue.put(AudioBlock(speech, 1.3))
        engine._drain_audio_blocks()
        with patch("asr.partial_engine.stream_utterance_text", return_value="我们接着看这个问题，然后把测试跑完。"):
            engine._process_active_utterance(2.0)
        for i in range(14, 24):  # 1.0s silence
            engine._audio_queue.put(AudioBlock(silence, i * 0.1))
        engine._drain_audio_blocks()
        with (
            self.assertLogs("asr.partial_engine", level="INFO") as logs,
            patch("asr.partial_engine.generate_utterance_text", return_value="我们接着看这个问题，然后把测试跑完。"),
        ):
            engine._process_active_utterance(2.0)

        self.assertIsNone(engine._utterance)
        self.assertEqual(cb.events[-1], ("final", 1, "我们接着看这个问题，然后把测试跑完。"))
        self.assertIn("endpoint=fast_close(closed_declarative)", "\n".join(logs.output))

    def test_idle_quiet_frames_gently_relax_inflated_noise_floor(self) -> None:
        engine, _ = self._make_engine()
        engine._config.vad_rms_threshold = 0.0
        engine._measured_noise_floor = 0.02
        engine._set_threshold(engine._config, engine._measured_noise_floor)
        before_threshold = engine.active_threshold

        quiet = np.full(1, 0.001, dtype=np.float32)
        for i in range(50):
            engine._audio_queue.put(AudioBlock(quiet, i * 0.1))
        engine._drain_audio_blocks()

        self.assertLess(engine.active_threshold, before_threshold)


if __name__ == "__main__":
    unittest.main()
