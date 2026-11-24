from __future__ import annotations

import unittest

from asr.asr_core import (
    AudioBlock,
    merge_context_system_prompt,
    stream_utterance_text,
    warm_up_asr_model,
)
from asr.config import AsrConfig
import numpy as np


class _Result:
    text = ""


class _FakeModel:
    def __init__(self) -> None:
        self.stream_calls: list[dict] = []
        self.generate_calls: list[dict] = []

    def stream_transcribe(self, audio_wave, **kwargs):
        self.stream_calls.append({"audio_len": len(audio_wave), **kwargs})
        yield _Result()

    def generate(self, audio_wave, **kwargs):
        self.generate_calls.append({"audio_len": len(audio_wave), **kwargs})
        return _Result()


class WarmUpAsrModelTests(unittest.TestCase):
    def test_warm_up_runs_stream_and_generate_with_configured_silence(self) -> None:
        model = _FakeModel()
        config = AsrConfig(
            language="Chinese",
            sample_rate=16_000,
            warmup_audio_seconds=1.0,
            stream_chunk_duration=1200.0,
            stream_min_chunk_duration=1.0,
        )

        stats = warm_up_asr_model(model, config)

        self.assertTrue(stats["stream_ms"] >= 0)
        self.assertTrue(stats["generate_ms"] >= 0)
        self.assertEqual(model.stream_calls, [
            {
                "audio_len": 16_000,
                "language": "Chinese",
                "system_prompt": None,
                "chunk_duration": 1200.0,
                "min_chunk_duration": 1.0,
                "verbose": False,
            }
        ])
        self.assertEqual(model.generate_calls, [
            {
                "audio_len": 16_000,
                "language": "Chinese",
                "system_prompt": None,
                "chunk_duration": 1200.0,
                "min_chunk_duration": 1.0,
                "verbose": False,
            }
        ])

    def test_warm_up_forwards_context_to_stream_and_final_paths(self) -> None:
        model = _FakeModel()
        context = "场景：前端和后端开发。术语：React、Redis、WebSocket。"
        config = AsrConfig(system_prompt=context)

        warm_up_asr_model(model, config)

        self.assertEqual(model.stream_calls[0]["system_prompt"], context)
        self.assertEqual(model.generate_calls[0]["system_prompt"], context)

    def test_stream_utterance_text_preserves_bpe_spaces_across_tokens(self) -> None:
        class _TokenResult:
            def __init__(self, text: str) -> None:
                self.text = text

        class _TokenStreamModel:
            def stream_transcribe(self, _audio_wave, **_kwargs):
                for piece in ["使用", " git", " commit", " 提交", " Pull", " Request"]:
                    yield _TokenResult(piece)

        block = AudioBlock(samples=np.zeros(160, dtype=np.float32), captured_at=0.0)
        text = stream_utterance_text(_TokenStreamModel(), [block], AsrConfig())
        self.assertEqual(text, "使用 git commit 提交 Pull Request")

    def test_stream_utterance_text_uses_generate_when_model_exposes_tokenizer(self) -> None:
        class _TokenizerModel:
            _tokenizer = object()

            def __init__(self) -> None:
                self.generate_called = 0

            def generate(self, _audio_wave, **_kwargs):
                self.generate_called += 1
                res = _Result()
                res.text = "打开 FastAPI 服务"
                return res

            def stream_transcribe(self, *_args, **_kwargs):
                raise AssertionError("should decode via generate when _tokenizer is present")

        model = _TokenizerModel()
        block = AudioBlock(samples=np.zeros(160, dtype=np.float32), captured_at=0.0)
        text = stream_utterance_text(model, [block], AsrConfig())
        self.assertEqual(text, "打开 FastAPI 服务")
        self.assertEqual(model.generate_called, 1)

    def test_merge_context_system_prompt_merges_and_caps_previous_context(self) -> None:
        merged = merge_context_system_prompt("场景：开发\n前文：上一句。", "这一句已确认。", max_chars=120)
        self.assertEqual(merged, "场景：开发\n前文：上一句。这一句已确认。")
        self.assertEqual(merge_context_system_prompt("前文：hello", "world", max_chars=120), "前文：hello world")
        self.assertEqual(merge_context_system_prompt("", "1234567890", max_chars=4), "前文：7890")


if __name__ == "__main__":
    unittest.main()
