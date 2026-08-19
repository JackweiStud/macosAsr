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
        self.assertIn("context_chars=0", summary)
        self.assertIn("previous_final_context=True", summary)
        self.assertIn("previous_final_context_chars=120", summary)
        self.assertIn("final_audio_trim=True", summary)
        self.assertIn("final_trailing_silence_keep=0.30s", summary)
        self.assertIn("sample_rate=16000", summary)
        self.assertIn("partial_interval=0.50s", summary)
        self.assertIn("partial_min_audio=0.60s", summary)
        self.assertIn("partial_max_audio=8.00s", summary)
        self.assertIn("partial_roll_min=8.00s", summary)
        self.assertIn("partial_roll_silence=0.40s", summary)
        self.assertIn("vad_end_silence=1.50s", summary)
        self.assertIn("vad_start_speech=0.20s", summary)
        self.assertIn("vad_min_utterance=0.60s", summary)
        self.assertIn("vad_pre_roll=0.50s", summary)
        self.assertIn("vad_soft_max_utterance=12.00s", summary)
        self.assertIn("vad_soft_break_silence=0.50s", summary)
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
        context = "场景：软件开发。术语：TypeScript、FastAPI、PostgreSQL。"

        apply_env_overrides(
            config,
            {
                "MACOSASR_CONTEXT": f"  {context}  ",
                "MACOSASR_PREVIOUS_FINAL_CONTEXT": "yes",
                "MACOSASR_PREVIOUS_FINAL_CONTEXT_CHARS": "80",
                "MACOSASR_FINAL_AUDIO_TRIM": "true",
                "MACOSASR_FINAL_TRAILING_SILENCE_KEEP": "0.25",
                "MACOSASR_PARTIAL_INTERVAL": "0.3",
                "MACOSASR_PARTIAL_MAX_AUDIO": "7.0",
                "MACOSASR_PARTIAL_ROLL_MIN": "5.0",
                "MACOSASR_PARTIAL_ROLL_SILENCE": "0.2",
                "MACOSASR_VAD_END_SILENCE": "2.0",
                "MACOSASR_VAD_SOFT_MAX_UTTERANCE": "9.5",
                "MACOSASR_VAD_SOFT_BREAK_SILENCE": "0.4",
            },
        )

        self.assertEqual(config.system_prompt, context)
        self.assertTrue(config.previous_final_context_enabled)
        self.assertEqual(config.previous_final_context_chars, 80)
        self.assertTrue(config.final_audio_trim_enabled)
        self.assertEqual(config.final_trailing_silence_keep_seconds, 0.25)
        self.assertEqual(config.partial_interval_seconds, 0.3)
        self.assertEqual(config.partial_max_audio_seconds, 7.0)
        self.assertEqual(config.partial_roll_min_seconds, 5.0)
        self.assertEqual(config.partial_roll_silence_seconds, 0.2)
        self.assertEqual(config.vad_end_silence_seconds, 2.0)
        self.assertEqual(config.vad_soft_max_utterance_seconds, 9.5)
        self.assertEqual(config.vad_soft_break_silence_seconds, 0.4)
        summary = config.log_summary()
        self.assertIn(f"context_chars={len(context)}", summary)
        self.assertNotIn(context, summary)

    def test_apply_env_overrides_can_disable_previous_final_context(self) -> None:
        config = AsrConfig(previous_final_context_enabled=True)

        apply_env_overrides(config, {"MACOSASR_PREVIOUS_FINAL_CONTEXT": "0"})

        self.assertFalse(config.previous_final_context_enabled)

    def test_apply_env_overrides_can_disable_final_audio_trim(self) -> None:
        config = AsrConfig(final_audio_trim_enabled=True)

        apply_env_overrides(config, {"MACOSASR_FINAL_AUDIO_TRIM": "0"})

        self.assertFalse(config.final_audio_trim_enabled)


if __name__ == "__main__":
    unittest.main()
