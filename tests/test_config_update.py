from __future__ import annotations

from pathlib import Path
import unittest

from asr.config import AsrConfig
from asr_daemon.server import DaemonServer


class ConfigUpdateTests(unittest.TestCase):
    def test_config_update_applies_partial_interval_and_vad_end_silence(self) -> None:
        config = AsrConfig()
        server = DaemonServer(Path("/tmp/macosasr-test.sock"), config, skip_model=True)

        events = server._dispatch(
            {
                "protocol": 1,
                "cmd": "config_update",
                "partial_interval_seconds": 0.8,
                "vad_end_silence_seconds": 2.0,
            }
        )

        self.assertEqual(config.partial_interval_seconds, 0.8)
        self.assertEqual(config.vad_end_silence_seconds, 2.0)
        self.assertEqual(events[0]["type"], "config_updated")
        self.assertEqual(events[0]["partial_interval_seconds"], 0.8)
        self.assertEqual(events[0]["vad_end_silence_seconds"], 2.0)

    def test_config_update_ignores_invalid_values(self) -> None:
        config = AsrConfig(partial_interval_seconds=0.5, vad_end_silence_seconds=1.5)
        server = DaemonServer(Path("/tmp/macosasr-test.sock"), config, skip_model=True)

        server._dispatch(
            {
                "protocol": 1,
                "cmd": "config_update",
                "partial_interval_seconds": "fast",
                "vad_end_silence_seconds": None,
            }
        )

        self.assertEqual(config.partial_interval_seconds, 0.5)
        self.assertEqual(config.vad_end_silence_seconds, 1.5)


class SettingsHotUpdateGuardrailTests(unittest.TestCase):
    def test_settings_hint_says_model_needs_app_restart(self) -> None:
        source = Path(__file__).resolve().parents[1].joinpath(
            "MacApp/macosAsrApp/SettingsWindowController.swift"
        ).read_text()
        self.assertIn("apply immediately", source)
        self.assertIn("ASR model requires restarting the app", source)
        self.assertIn("pushRuntimeDictationSettings()", source)

    def test_daemon_manager_pushes_config_update(self) -> None:
        source = Path(__file__).resolve().parents[1].joinpath(
            "MacApp/macosAsrApp/DaemonManager.swift"
        ).read_text()
        self.assertIn('cmd: "config_update"', source)
        self.assertIn("partial_interval_seconds", source)
        self.assertIn("vad_end_silence_seconds", source)
        self.assertIn("pushRuntimeDictationSettings()", source)


class SessionStartMicErrorTests(unittest.TestCase):
    def test_session_start_returns_error_instead_of_raising(self) -> None:
        class _BoomSession:
            def start_session(self, language=None) -> str:
                raise RuntimeError("Internal PortAudio error [PaErrorCode -9986]")

        server = DaemonServer(Path("/tmp/macosasr-test.sock"), AsrConfig(), skip_model=True)
        server._session = _BoomSession()  # type: ignore[assignment]

        events = server._dispatch({"protocol": 1, "cmd": "session_start", "language": "Chinese"})

        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["type"], "error")
        self.assertEqual(events[0]["code"], "mic_open_failed")
        self.assertIn("PortAudio", events[0]["message"])

    def test_client_handler_catches_dispatch_exceptions(self) -> None:
        source = Path(__file__).resolve().parents[1].joinpath("asr_daemon/server.py").read_text()
        self.assertIn('"code": "dispatch_failed"', source)
        self.assertIn("session_start failed", source)

    def test_live_dictation_reverts_on_mic_error(self) -> None:
        source = Path(__file__).resolve().parents[1].joinpath(
            "MacApp/macosAsrApp/LiveDictationController.swift"
        ).read_text()
        self.assertIn("revertListeningAfterError", source)
        self.assertIn('case "warning":', source)
        self.assertIn("abortListeningAfterDaemonError", source)


if __name__ == "__main__":
    unittest.main()
