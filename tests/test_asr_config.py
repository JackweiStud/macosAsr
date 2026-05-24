from __future__ import annotations

import unittest

from asr.config import AsrConfig
from asr_daemon.__main__ import apply_env_overrides


class AsrConfigTests(unittest.TestCase):
    def test_default_end_silence_waits_for_thinking_pauses(self) -> None:
        self.assertEqual(AsrConfig().vad_end_silence_seconds, 1.5)

    def test_log_summary_includes_runtime_tuning_values(self) -> None:
        config = AsrConfig()

        summary = config.log_summary()

        self.assertIn("model=mlx-community/Qwen3-ASR-0.6B-8bit", summary)
        self.assertIn("language=Chinese", summary)
        self.assertIn("sample_rate=16000", summary)
        self.assertIn("partial_interval=0.50s", summary)
        self.assertIn("partial_min_audio=0.60s", summary)
        self.assertIn("vad_end_silence=1.50s", summary)
        self.assertIn("vad_start_speech=0.20s", summary)
        self.assertIn("vad_min_utterance=0.60s", summary)
        self.assertIn("vad_pre_roll=0.50s", summary)
        self.assertIn("vad_max_utterance=20.00s", summary)
        self.assertIn("noise_calibration=3.00s", summary)
        self.assertIn("noise_multiplier=3.00", summary)
        self.assertIn("noise_margin=0.0030", summary)
        self.assertIn("noise_max_threshold=0.0500", summary)
        self.assertIn("stream_chunk_duration=1200.00", summary)
        self.assertIn("stream_min_chunk_duration=1.00", summary)
        self.assertIn("warmup_enabled=True", summary)
        self.assertIn("warmup_audio=1.00s", summary)
        self.assertIn("min_final_chars=2", summary)
        self.assertIn("filter_fillers=True", summary)

    def test_apply_env_overrides_accepts_developer_tuning_values(self) -> None:
        config = AsrConfig()

        apply_env_overrides(
            config,
            {
                "MACOSASR_PARTIAL_INTERVAL": "0.3",
                "MACOSASR_VAD_END_SILENCE": "2.0",
            },
        )

        self.assertEqual(config.partial_interval_seconds, 0.3)
        self.assertEqual(config.vad_end_silence_seconds, 2.0)


if __name__ == "__main__":
    unittest.main()
