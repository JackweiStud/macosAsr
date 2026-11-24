from __future__ import annotations

import unittest
from unittest.mock import patch

import numpy as np

from asr.asr_core import AudioBlock
from asr.config import AsrConfig
from asr.oral_polisher import (
    OralPolisher,
    PolishResult,
    clean_oral_rules,
    validate_polished_output,
)
from asr.partial_engine import PartialEngine, _UtteranceState


class _FakeTokenizer:
    def apply_chat_template(self, messages, **_kwargs):
        return messages[-1]["content"]


class OralPolisherRuleAndGuardrailTests(unittest.TestCase):
    def test_clean_oral_rules_strips_standalone_fillers_and_punctuated_stutters(self) -> None:
        raw = "啊，默认关闭。第二个A选项热词的话，嗯，你可以。呃，当然支持用户进行修改、增删、增删。"
        self.assertEqual(
            clean_oral_rules(raw),
            "默认关闭。第二个A选项热词的话，你可以。当然支持用户进行修改、增删。",
        )

    def test_clean_oral_rules_preserves_normal_reduplication_and_clean_text(self) -> None:
        clean = "我们好好看看 FastAPI 和 PostgreSQL，谢谢。"
        self.assertEqual(clean_oral_rules(clean), clean)

    def test_validate_polished_output_blocks_truncation_expansion_and_lost_terms(self) -> None:
        orig = "你是怎么能？解决的，首先是识别到这些问题的，然后再一一解决。最关键是怎么把这些问题识别出来的？"
        ok, reason = validate_polished_output(orig, "你是怎么解决的？我怎么解决的？")
        self.assertFalse(ok)
        self.assertEqual(reason, "truncated")

        ok_exp, reason_exp = validate_polished_output(
            "这个问题是不是已经彻底解决了？",
            "这个问题已经通过四项核心突破彻底解决了，你可以直接开始测试验证体验效果如何。",
        )
        self.assertFalse(ok_exp)
        self.assertEqual(reason_exp, "expanded")

        ok_term, reason_term = validate_polished_output(
            "启动 FastAPI 服务连接 PostgreSQL 数据库，端口 5432。",
            "启动接口服务连接数据库，端口 5432。",
        )
        self.assertFalse(ok_term)
        self.assertEqual(reason_term, "lost_protected_token")

        ok_meta, reason_meta = validate_polished_output(
            "帮我把这个分支合并到 main。",
            "好的，帮我把这个分支合并到 main。",
        )
        self.assertFalse(ok_meta)
        self.assertEqual(reason_meta, "meta_prefix")

    def test_validate_polished_output_accepts_good_self_repair_and_punctuation_polish(self) -> None:
        orig = "这两项表达，这两项修改，达到了如此好的效果吗？"
        cand = "这两项修改达到了如此好的效果吗？"
        ok, reason = validate_polished_output(orig, cand)
        self.assertTrue(ok, reason)

    def test_polisher_disabled_and_short_utterance_never_load_llm(self) -> None:
        loads = 0

        def fake_loader(_model_id: str):
            nonlocal loads
            loads += 1
            return object(), _FakeTokenizer()

        polisher = OralPolisher(loader=fake_loader)
        disabled = polisher.polish("啊，默认关闭。", AsrConfig(oral_polish_enabled=False))
        self.assertEqual(disabled.mode, "disabled")
        self.assertEqual(disabled.text, "啊，默认关闭。")
        self.assertEqual(loads, 0)

        short = polisher.polish("啊，好的，没问题。", AsrConfig(oral_polish_enabled=True, oral_polish_min_chars=10))
        self.assertEqual(short.mode, "rules_only")
        self.assertEqual(short.text, "好的，没问题。")
        self.assertEqual(loads, 0)

    def test_polisher_applies_llm_and_falls_back_to_rules_on_guardrail_rejection(self) -> None:
        responses = iter([
            "这两项修改达到了如此好的效果吗？",
            "你是怎么解决的？",
        ])
        polisher = OralPolisher(
            loader=lambda _mid: (object(), _FakeTokenizer()),
            generator=lambda _m, _t, **_kw: next(responses),
        )
        cfg = AsrConfig(oral_polish_enabled=True, oral_polish_min_chars=10)

        res1 = polisher.polish("这两项表达，这两项修改，达到了如此好的效果吗？", cfg)
        self.assertEqual(res1.mode, "llm")
        self.assertEqual(res1.text, "这两项修改达到了如此好的效果吗？")
        self.assertTrue(polisher.is_loaded)

        res2 = polisher.polish(
            "嗯，你是怎么能解决的，首先是识别到这些问题的，然后再一一解决，最关键是怎么把这些问题识别出来的？",
            cfg,
        )
        self.assertEqual(res2.mode, "fallback_rules")
        self.assertEqual(res2.reason, "rejected:truncated")
        self.assertIn("最关键是怎么把这些问题识别出来的", res2.text)

        polisher.unload()
        self.assertFalse(polisher.is_loaded)


class PartialEngineOralPolishIntegrationTests(unittest.TestCase):
    def test_finalize_invokes_polisher_only_when_enabled_and_unload_runs_on_toggle_off(self) -> None:
        events: list[tuple[str, str]] = []

        class _CB:
            def on_partial(self, _u, _t, _s): pass
            def on_final(self, _u, t, _s): events.append(("final", t))
            def on_filtered(self, _u, _t, r, _s): events.append(("filtered", r))
            def on_warning(self, _m, _c): pass
            def on_error(self, m): raise AssertionError(m)

        cfg = AsrConfig(
            sample_rate=10,
            vad_min_utterance_seconds=0.1,
            final_audio_trim_enabled=False,
            filter_fillers=False,
            min_final_chars=1,
            oral_polish_enabled=True,
        )
        engine = PartialEngine(cfg, _CB())
        engine._model = object()

        unloaded = []
        preloaded = []

        class _StubPolisher:
            def polish(self, text: str, _cfg: AsrConfig) -> PolishResult:
                return PolishResult(text="这两项修改达到了如此好的效果吗？", mode="llm", reason="ok", elapsed_ms=120.0)

            def preload_if_cached(self, model_id: str) -> bool:
                preloaded.append(model_id)
                return True

            def unload(self) -> None:
                unloaded.append(True)

        engine._polisher = _StubPolisher()  # type: ignore[assignment]
        utterance = _UtteranceState(
            utterance_id=1,
            blocks=[AudioBlock(samples=np.ones(2, dtype=np.float32), captured_at=0.0)],
            started_at=0.0,
            last_voice_at=0.0,
            speech_started_at=0.0,
            silence_run_seconds=0.1,
        )

        with (
            self.assertLogs("asr.partial_engine", level="INFO") as logs,
            patch("asr.partial_engine.generate_utterance_text", return_value="这两项表达，这两项修改，达到了如此好的效果吗？"),
        ):
            engine._finalize_utterance(utterance, reason="silence")

        self.assertEqual(events, [("final", "这两项修改达到了如此好的效果吗？")])
        self.assertIn("polish=llm(ok,120ms)", "\n".join(logs.output))

        engine.set_oral_polish_enabled(False)
        engine._drain_control_queue()
        self.assertFalse(cfg.oral_polish_enabled)
        self.assertEqual(unloaded, [True])

        engine.set_oral_polish_enabled(True)
        engine._drain_control_queue()
        self.assertTrue(cfg.oral_polish_enabled)
        self.assertEqual(preloaded, [cfg.oral_polish_model])


if __name__ == "__main__":
    unittest.main()
