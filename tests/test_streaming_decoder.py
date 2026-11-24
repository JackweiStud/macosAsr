from __future__ import annotations

import types
import unittest
from unittest.mock import patch

import numpy as np

from asr.asr_core import AudioBlock
from asr.config import AsrConfig
from asr.partial_engine import PartialEngine, _UtteranceState
from asr.streaming_decoder import (
    StreamingStepResult,
    _trim_safe_prefix_tokens,
    supports_native_streaming,
)


class _FakeTokenizer:
    def __init__(self, vocab: dict[int, str]) -> None:
        self._vocab = vocab

    def decode(self, ids: list[int], skip_special_tokens: bool = True) -> str:
        return "".join(self._vocab.get(i, "") for i in ids)


class _FakeQwenInner:
    def __init__(self) -> None:
        self.config = types.SimpleNamespace(
            audio_config=types.SimpleNamespace(n_window_infer=800),
            audio_token_id=151676,
        )
        self._feature_extractor = object()
        self._tokenizer = object()

    def get_audio_features(self, *args, **kwargs):
        raise NotImplementedError

    def _build_prompt(self, *args, **kwargs):
        raise NotImplementedError


class _FakeQwenWrapper:
    def __init__(self) -> None:
        self._model = _FakeQwenInner()


class _Callback:
    def __init__(self) -> None:
        self.events: list[tuple[str, int, str, float]] = []

    def on_partial(self, uid: int, text: str, started: float) -> None:
        self.events.append(("partial", uid, text, started))

    def on_final(self, uid: int, text: str, started: float) -> None:
        self.events.append(("final", uid, text, started))

    def on_filtered(self, uid: int, text: str, reason: str, started: float) -> None:
        self.events.append(("filtered", uid, reason, started))

    def on_warning(self, message: str, code: str) -> None:
        pass

    def on_error(self, message: str) -> None:
        raise AssertionError(message)


def _blocks(start: float, count: int, voiced: bool = True) -> list[AudioBlock]:
    return [
        AudioBlock(np.full(1, 0.5 if voiced else 0.0, dtype=np.float32), start + i / 10.0)
        for i in range(count)
    ]


class StreamingDecoderUnitTests(unittest.TestCase):
    def test_supports_native_streaming_detects_qwen3_wrapper_and_rejects_plain_mocks(self) -> None:
        self.assertTrue(supports_native_streaming(_FakeQwenWrapper()))
        self.assertTrue(supports_native_streaming(_FakeQwenInner()))
        self.assertFalse(supports_native_streaming(object()))
        self.assertFalse(supports_native_streaming(None))

    def test_trim_safe_prefix_tokens_protects_ascii_words_utf8_and_monotonicity(self) -> None:
        tok = _FakeTokenizer({
            1: "连接",
            2: " Post",
            3: "gre",
            4: "SQL",
            5: " 数",
            6: "据",
            7: "库",
            8: "\ufffd",
            9: "吧",
        })
        # Cut at index 3 splits " Post" | "gre" | "SQL"; must step back before " Post" (index 1).
        trimmed = _trim_safe_prefix_tokens([1, 2, 3, 4, 5, 6], unfixed_tokens=3, tokenizer=tok, min_len=0)
        self.assertEqual(trimmed, [1])

        # Trailing incomplete UTF-8 (\ufffd) must be popped cleanly.
        trimmed_utf8 = _trim_safe_prefix_tokens([1, 8, 9], unfixed_tokens=1, tokenizer=tok, min_len=0)
        self.assertEqual(trimmed_utf8, [1])

        # Never shrink below existing committed min_len.
        monotonic = _trim_safe_prefix_tokens([1, 2, 3], unfixed_tokens=2, tokenizer=tok, min_len=2)
        self.assertEqual(monotonic, [1, 2])


class PartialEngineNativeStreamingTests(unittest.TestCase):
    def test_native_streaming_runs_past_8s_without_rolling_checkpoints_and_resets_on_final(self) -> None:
        callback = _Callback()
        cfg = AsrConfig(
            sample_rate=10,
            input_block_seconds=0.1,
            partial_interval_seconds=0.0,
            partial_min_audio_seconds=0.1,
            partial_max_audio_seconds=1.0,
            rolling_max_audio_seconds=2.0,
            streaming_seal_min_seconds=4.0,
            streaming_max_audio_seconds=5.0,
            vad_end_silence_seconds=0.3,
            vad_min_utterance_seconds=0.1,
            final_audio_trim_enabled=False,
            filter_fillers=False,
            min_final_chars=1,
            native_streaming_enabled=True,
        )
        engine = PartialEngine(cfg, callback)
        engine._model = _FakeQwenWrapper()
        engine._active_threshold = 0.1
        engine._clock_offset = lambda: 1000.0
        engine.set_listening(True)

        utterance = _UtteranceState(
            utterance_id=3,
            blocks=_blocks(10.0, 25),  # 2.5s > partial_max_audio_seconds (1.0s) and rolling_max (2.0s)
            started_at=10.0,
            last_voice_at=12.4,
            speech_started_at=10.0,
            speech_started_at_unix=1010.0,
            audio_seconds=2.5,
        )
        engine._utterance = utterance

        calls: list[tuple[bool, int]] = []
        resets: list[int] = []

        class _FakeSession:
            def __init__(self, _model) -> None:
                pass

            def decode(self, blocks, _config, *, is_final: bool = False) -> StreamingStepResult:
                calls.append((is_final, len(blocks)))
                text = "长句定稿结果。" if is_final else "长句实时结果"
                return StreamingStepResult(text=text, prefix_tokens=4, generated_tokens=3, cached_blocks=1, encoded_blocks=1, elapsed_ms=120.0)

            def reset(self) -> None:
                resets.append(1)

        with (
            patch("asr.partial_engine.Qwen3StreamingSession", _FakeSession),
            patch("asr.partial_engine.generate_utterance_text") as legacy_gen,
            patch("asr.partial_engine.stream_utterance_text") as legacy_stream,
        ):
            engine._process_active_utterance(0.3)
            self.assertEqual(calls, [(False, 25)])
            self.assertEqual(callback.events, [("partial", 3, "长句实时结果", 1010.0)])

            utterance.silence_run_seconds = 0.3
            engine._process_active_utterance(0.3)
            self.assertEqual(calls, [(False, 25), (True, 25)])
            self.assertEqual(callback.events[-1], ("final", 3, "长句定稿结果。", 1010.0))
            self.assertEqual(len(resets), 1)
            legacy_gen.assert_not_called()
            legacy_stream.assert_not_called()

    def test_native_streaming_seals_at_max_audio_ceiling_preserving_identity_and_context(self) -> None:
        callback = _Callback()
        cfg = AsrConfig(
            sample_rate=10,
            input_block_seconds=0.1,
            partial_interval_seconds=0.0,
            partial_min_audio_seconds=0.1,
            streaming_seal_min_seconds=3.0,
            streaming_max_audio_seconds=3.0,
            vad_end_silence_seconds=0.3,
            vad_min_utterance_seconds=0.1,
            final_audio_trim_enabled=False,
            filter_fillers=False,
            min_final_chars=1,
            native_streaming_enabled=True,
            previous_final_context_enabled=True,
        )
        engine = PartialEngine(cfg, callback)
        engine._model = _FakeQwenWrapper()
        engine._active_threshold = 0.1
        engine._clock_offset = lambda: 1000.0
        engine.set_listening(True)

        utterance = _UtteranceState(
            utterance_id=9,
            blocks=_blocks(10.0, 30),  # 3.0s == streaming_max_audio_seconds
            started_at=10.0,
            last_voice_at=12.9,
            speech_started_at=10.0,
            speech_started_at_unix=1010.0,
            audio_seconds=3.0,
        )
        engine._utterance = utterance

        prompts_seen: list[str] = []
        outputs = iter(["第一段四十八秒内容，", "第二段继续说。"])

        class _FakeSession:
            def __init__(self, _model) -> None:
                self.reset_count = 0

            def decode(self, _blocks, config, *, is_final: bool = False) -> StreamingStepResult:
                prompts_seen.append(config.system_prompt)
                return StreamingStepResult(text=next(outputs), prefix_tokens=10, generated_tokens=4, cached_blocks=3, encoded_blocks=1, elapsed_ms=180.0)

            def reset(self) -> None:
                self.reset_count += 1

        with patch("asr.partial_engine.Qwen3StreamingSession", _FakeSession):
            engine._process_active_utterance(0.3)
            self.assertIs(engine._utterance, utterance)
            self.assertEqual(utterance.blocks, [])
            self.assertEqual(utterance.native_seal_count, 1)
            self.assertEqual(utterance.transcript.committed, "第一段四十八秒内容，")
            self.assertEqual(callback.events, [("partial", 9, "第一段四十八秒内容，", 1010.0)])

            utterance.blocks.extend(_blocks(13.0, 5))
            utterance.window_has_voice = True
            utterance.silence_run_seconds = 0.3
            engine._process_active_utterance(0.3)

        self.assertEqual(prompts_seen[0], "")
        self.assertEqual(prompts_seen[1], "前文：第一段四十八秒内容，")
        self.assertEqual(callback.events[-1], ("final", 9, "第一段四十八秒内容，第二段继续说。", 1010.0))


if __name__ == "__main__":
    unittest.main()
