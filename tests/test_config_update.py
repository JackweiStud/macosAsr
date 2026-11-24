from __future__ import annotations

from pathlib import Path
import unittest

from asr.asr_core import format_hotwords_prompt, is_prompt_echo_hallucination
from asr.config import AsrConfig
from asr_daemon.server import DaemonServer
from asr_daemon.session import SessionController


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
            "MacApp/macosAsrApp/DaemonManager.swift"
        ).read_text()
        self.assertIn('event.code == "mic_open_failed"', source)
        self.assertIn("sessionLifecycle.microphoneOpenFailed(message)", source)
        self.assertIn("sessionLifecycle.daemonFailed(message)", source)


class HotwordsAndScreenContextTests(unittest.TestCase):
    def test_format_hotwords_prompt_deduplicates_and_normalizes(self) -> None:
        formatted = format_hotwords_prompt("FastAPI, postgresql，PostgreSQL\nWebSocket；macosAsr")
        self.assertEqual(formatted, "常用术语：FastAPI, postgresql, WebSocket, macosAsr")
        self.assertEqual(format_hotwords_prompt("   , ,\n"), "")
        self.assertEqual(format_hotwords_prompt("场景：开发"), "场景：开发")

    def test_config_update_hot_updates_custom_hotwords_and_preserves_layers(self) -> None:
        class _StubEngine:
            calibrated = True
            warmed_up = True
            recording_active = False

            def start_recording(self) -> None:
                pass

            def stop_recording(self) -> None:
                pass

            def set_listening(self, _listening: bool) -> None:
                pass

            def is_listening(self) -> bool:
                return False

            def flush_on_stop(self) -> None:
                pass

            def discard_utterance(self, _before: float) -> None:
                pass

        config = AsrConfig()
        engine = _StubEngine()
        session = SessionController(engine, config, lambda _e: None)  # type: ignore[arg-type]
        server = DaemonServer(Path("/tmp/macosasr-hotwords-test.sock"), config, skip_model=True)
        server._session = session

        events = server._dispatch({
            "protocol": 1,
            "cmd": "config_update",
            "custom_hotwords": "FastAPI, PostgreSQL, macosAsr",
        })
        self.assertEqual(events[0]["type"], "config_updated")
        self.assertEqual(config.system_prompt, "常用术语：FastAPI, PostgreSQL, macosAsr")

        # Start session with optional ephemeral screen context.
        server._dispatch({
            "protocol": 1,
            "cmd": "session_start",
            "language": "Chinese",
            "session_context": "当前窗口：Cursor - partial_engine.py；光标前文：测试热词",
        })
        self.assertEqual(
            config.system_prompt,
            "常用术语：FastAPI, PostgreSQL, macosAsr\n当前窗口：Cursor - partial_engine.py；光标前文：测试热词",
        )

        # Previous final context layers after base hotwords + session context.
        session.on_final(1, "先看第一句。", 100.0)
        self.assertEqual(
            config.system_prompt,
            "常用术语：FastAPI, PostgreSQL, macosAsr\n当前窗口：Cursor - partial_engine.py；光标前文：测试热词\n前文：先看第一句。",
        )

        # Stopping clears ephemeral session_context and previous_final, keeping base hotwords.
        session.stop_session()
        self.assertEqual(config.system_prompt, "常用术语：FastAPI, PostgreSQL, macosAsr")

        # Clearing hotwords empties system_prompt immediately.
        server._dispatch({"protocol": 1, "cmd": "config_update", "custom_hotwords": ""})
        self.assertEqual(config.system_prompt, "")

    def test_swift_defaults_and_privacy_guardrails(self) -> None:
        root = Path(__file__).resolve().parents[1]
        app_config = (root / "MacApp/macosAsrApp/AppConfig.swift").read_text()
        self.assertIn("static let defaultScreenContextEnabled = false", app_config)
        self.assertIn("static let defaultCustomHotwords =", app_config)

        reader = (root / "MacApp/macosAsrApp/ScreenContextReader.swift").read_text()
        self.assertIn("IsSecureEventInputEnabled()", reader)
        self.assertIn("kAXSecureTextFieldSubrole", reader)

        settings = (root / "MacApp/macosAsrApp/SettingsWindowController.swift").read_text()
        self.assertIn("screenContextCheckbox", settings)
        self.assertIn("hotwordsTextView", settings)
        self.assertIn("oralPolishPopUp", settings)
        self.assertIn("static let defaultOralPolishEnabled = false", app_config)

    def test_config_update_toggles_oral_polish_enabled(self) -> None:
        config = AsrConfig(oral_polish_enabled=False)
        server = DaemonServer(Path("/tmp/macosasr-polish-test.sock"), config, skip_model=True)

        events = server._dispatch({"protocol": 1, "cmd": "config_update", "oral_polish_enabled": True})
        self.assertTrue(config.oral_polish_enabled)
        self.assertTrue(events[0]["oral_polish_enabled"])

        events_off = server._dispatch({"protocol": 1, "cmd": "config_update", "oral_polish_enabled": False})
        self.assertFalse(config.oral_polish_enabled)
        self.assertFalse(events_off[0]["oral_polish_enabled"])

    def test_prompt_echo_hallucination_guardrail(self) -> None:
        prompt = "常用术语：FastAPI, PostgreSQL\n当前窗口：T3 Code (Beta) - T3 Code (Beta)\n前文：主干上推到远端。"
        leaked = "当前窗口：T3 Code (Beta) - T3 Code (Beta) 前文：主干上推到远端。"
        self.assertTrue(is_prompt_echo_hallucination(leaked, prompt, audio_seconds=0.80))
        self.assertTrue(is_prompt_echo_hallucination("当前窗口：T3 Code (Beta)", prompt, audio_seconds=1.2))
        # Real speech mentioning similar words without echoing prompt markers must pass.
        self.assertFalse(is_prompt_echo_hallucination("请帮我把当前窗口关掉。", prompt, audio_seconds=2.0))
        self.assertFalse(is_prompt_echo_hallucination("主干上推到远端。", prompt, audio_seconds=3.0))


if __name__ == "__main__":
    unittest.main()
