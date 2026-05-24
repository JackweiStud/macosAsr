from __future__ import annotations

import unittest

from asr.asr_core import warm_up_asr_model
from asr.config import AsrConfig


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
                "chunk_duration": 1200.0,
                "min_chunk_duration": 1.0,
                "verbose": False,
            }
        ])
        self.assertEqual(model.generate_calls, [
            {
                "audio_len": 16_000,
                "language": "Chinese",
                "chunk_duration": 1200.0,
                "min_chunk_duration": 1.0,
                "verbose": False,
            }
        ])


if __name__ == "__main__":
    unittest.main()
