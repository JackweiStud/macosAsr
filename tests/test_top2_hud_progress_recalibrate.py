from __future__ import annotations

from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import numpy as np

from asr.asr_core import AudioBlock
from asr.config import AsrConfig
from asr.model_download import make_progress_tqdm_class, resolve_or_download_model
from asr.oral_polisher import PolishResult
from asr.partial_engine import PartialEngine, _UtteranceState
from asr_daemon.server import DaemonServer
from asr_daemon.session import SessionController


class _BaseDummyTqdm:
    def __init__(self, *args, **kwargs) -> None:
        self.total = kwargs.get("total") or 0
        self.n = kwargs.get("initial") or 0
        self.desc = kwargs.get("desc") or ""

    def update(self, n=1) -> None:
        if n:
            self.n += n

    def refresh(self) -> None:
        pass

    def set_description(self, desc="", refresh=True) -> None:
        self.desc = desc
        if refresh:
            self.refresh()


class ModelDownloadProgressTests(unittest.TestCase):
    def test_cached_model_returns_local_path_without_downloading(self) -> None:
        events: list[tuple[str, float | None, int, int]] = []
        with tempfile.TemporaryDirectory() as tmp:
            def fake_snapshot(repo_id: str, **kwargs) -> str:
                self.assertEqual(repo_id, "mlx-community/Qwen3-ASR-0.6B-8bit")
                self.assertTrue(kwargs.get("local_files_only"))
                return tmp

            resolved = resolve_or_download_model(
                "mlx-community/Qwen3-ASR-0.6B-8bit",
                on_progress=lambda s, p, d, t: events.append((s, p, d, t)),
                snapshot_download_fn=fake_snapshot,
            )
            self.assertEqual(resolved, tmp)
            self.assertEqual(events, [("loading", None, 0, 0)])

    def test_uncached_model_emits_byte_progress_and_ignores_file_count_bar(self) -> None:
        events: list[tuple[str, float | None, int, int]] = []

        def fake_snapshot(_repo_id: str, **kwargs) -> str:
            if kwargs.get("local_files_only"):
                raise FileNotFoundError("not cached")
            tqdm_cls = kwargs["tqdm_class"]
            # File-count bar (no unit="B") must be ignored.
            file_bar = tqdm_cls(total=5, desc="Fetching 5 files")
            file_bar.update(1)
            # Byte-level aggregated bar drives progress.
            bytes_bar = tqdm_cls(total=0, initial=0, unit="B", desc="Downloading")
            bytes_bar.total += 1000
            bytes_bar.refresh()
            bytes_bar.update(420)
            bytes_bar.update(580)
            bytes_bar.set_description("Download complete")
            return "/tmp/fake-model"

        resolved = resolve_or_download_model(
            "mlx-community/Qwen3-ASR-0.6B-8bit",
            on_progress=lambda s, p, d, t: events.append((s, p, d, t)),
            snapshot_download_fn=fake_snapshot,
        )
        self.assertEqual(resolved, "/tmp/fake-model")
        self.assertEqual(events[0][0], "downloading")
        self.assertEqual(events[0][1], 0.0)
        ratios = [p for stage, p, _d, _t in events if stage == "downloading" and p is not None]
        self.assertIn(0.42, ratios)
        self.assertIn(1.0, ratios)
        self.assertEqual(events[-1], ("loading", None, 0, 0))

    def test_progress_tqdm_clamps_and_formats_ratios(self) -> None:
        seen: list[tuple[str, float | None, int, int]] = []
        cls = make_progress_tqdm_class(
            lambda s, p, d, t: seen.append((s, p, d, t)),
            min_interval_seconds=0.0,
            base_cls=_BaseDummyTqdm,
        )
        bar = cls(total=200, initial=0, unit="B")
        bar.update(50)
        bar.update(250)  # Exceeding total clamps to 1.0
        self.assertEqual(seen[0], ("downloading", 0.25, 50, 200))
        self.assertEqual(seen[-1], ("downloading", 1.0, 200, 200))


class PingProgressAndRecalibrateTests(unittest.TestCase):
    def test_ping_reports_stage_and_download_progress(self) -> None:
        cfg = AsrConfig()
        server = DaemonServer(Path("/tmp/macosasr-ping-progress.sock"), cfg, skip_model=True)

        class _StubEngine:
            model_loaded = False
            warmed_up = False
            calibrated = False

            def load_status(self) -> dict[str, object]:
                return {
                    "stage": "downloading",
                    "download_progress": 0.4215,
                    "downloaded_bytes": 421_500,
                    "total_bytes": 1_000_000,
                }

        server._engine = _StubEngine()  # type: ignore[assignment]
        pong = server._dispatch({"protocol": 1, "cmd": "ping"})[0]
        self.assertEqual(pong["type"], "pong")
        self.assertEqual(pong["stage"], "downloading")
        self.assertEqual(pong["download_progress"], 0.4215)
        self.assertEqual(pong["downloaded_bytes"], 421_500)
        self.assertEqual(pong["total_bytes"], 1_000_000)

    def test_recalibrate_noise_rejects_active_session_and_runs_when_idle(self) -> None:
        emitted: list[dict] = []
        cfg = AsrConfig(noise_calibration_seconds=0.0, noise_margin=0.004)
        engine = PartialEngine(cfg, callback=None)  # type: ignore[arg-type]
        session = SessionController(engine, cfg, emitted.append)
        engine._callback = session
        engine._model_loaded = True

        server = DaemonServer(Path("/tmp/macosasr-recal.sock"), cfg, skip_model=True)
        server._engine = engine
        server._session = session

        # Active session must be rejected cleanly.
        session._session_id = "s-active"
        rejected = server._dispatch({"protocol": 1, "cmd": "recalibrate_noise"})[0]
        self.assertEqual(rejected["type"], "error")
        self.assertEqual(rejected["code"], "session_active")

        # Idle session accepts and runs calibration cleanly on worker.
        session._session_id = None
        mic_ops: list[str] = []
        engine._open_mic_stream = lambda: mic_ops.append("open")  # type: ignore[method-assign]
        engine._close_mic_stream = lambda: mic_ops.append("close")  # type: ignore[method-assign]

        accepted = server._dispatch({"protocol": 1, "cmd": "recalibrate_noise"})[0]
        self.assertEqual(accepted["type"], "recalibrate_accepted")
        self.assertTrue(accepted["accepted"])

        engine._drain_control_queue()
        self.assertEqual(mic_ops, ["open", "close"])
        types = [e["type"] for e in emitted]
        self.assertEqual(types, ["calibration_started", "calibration_done"])
        self.assertEqual(emitted[-1]["threshold"], 0.004)
        self.assertFalse(engine.recalibrating)

    def test_audio_level_and_polishing_callbacks_emit_cleanly(self) -> None:
        emitted: list[dict] = []
        cfg = AsrConfig(
            sample_rate=10,
            vad_min_utterance_seconds=0.1,
            final_audio_trim_enabled=False,
            filter_fillers=False,
            min_final_chars=1,
            oral_polish_enabled=True,
            oral_polish_min_chars=5,
        )
        engine = PartialEngine(cfg, callback=None)  # type: ignore[arg-type]
        session = SessionController(engine, cfg, emitted.append)
        engine._callback = session
        engine._model = object()
        engine._active_threshold = 0.01
        session._session_id = "s-live"

        # Audio level emission
        engine._last_level_emit_at = 0.0
        engine._emit_audio_level_if_due(0.025, speaking=True)
        level_events = [e for e in emitted if e["type"] == "audio_level"]
        self.assertEqual(len(level_events), 1)
        self.assertTrue(0.0 < level_events[0]["level"] <= 1.0)
        self.assertTrue(level_events[0]["speaking"])

        # Polishing event right before final
        class _StubPolisher:
            def polish(self, text: str, _cfg: AsrConfig) -> PolishResult:
                return PolishResult(text=text, mode="llm", reason="ok", elapsed_ms=10.0)

        engine._polisher = _StubPolisher()  # type: ignore[assignment]
        utterance = _UtteranceState(
            utterance_id=3,
            blocks=[AudioBlock(samples=np.ones(2, dtype=np.float32), captured_at=0.0)],
            started_at=0.0,
            last_voice_at=0.0,
            speech_started_at=0.0,
            silence_run_seconds=0.1,
        )
        with patch("asr.partial_engine.generate_utterance_text", return_value="这是一段需要顺稿的测试文本。"):
            engine._finalize_utterance(utterance, reason="silence")

        event_types = [e["type"] for e in emitted]
        self.assertIn("polishing", event_types)
        self.assertLess(event_types.index("polishing"), event_types.index("final"))


class FloatingHUDGuardrailTests(unittest.TestCase):
    def test_floating_hud_is_strictly_non_activating_and_draggable(self) -> None:
        root = Path(__file__).resolve().parents[1]
        hud_src = (root / "MacApp/macosAsrApp/FloatingHUDController.swift").read_text()
        self.assertIn(".nonactivatingPanel", hud_src)
        self.assertIn("override var canBecomeKey: Bool { false }", hud_src)
        self.assertIn("override var canBecomeMain: Bool { false }", hud_src)
        self.assertIn("panel.orderFrontRegardless()", hud_src)
        self.assertIn("containsQuartzPoint", hud_src)
        self.assertIn("override func mouseDragged", hud_src)
        self.assertNotIn("makeKeyAndOrderFront", hud_src)

        hotkey_src = (root / "MacApp/macosAsrApp/GlobalHotkeyMonitor.swift").read_text()
        self.assertIn("shouldIgnoreMouseEvent", hotkey_src)

        app_delegate = (root / "MacApp/macosAsrApp/AppDelegate.swift").read_text()
        self.assertIn("Recalibrate Noise…", app_delegate)
        self.assertIn("⏳ \\(pct)%", app_delegate)
        self.assertIn("containsQuartzPoint", app_delegate)

        app_config = (root / "MacApp/macosAsrApp/AppConfig.swift").read_text()
        self.assertIn("static let defaultHudEnabled = true", app_config)


if __name__ == "__main__":
    unittest.main()
