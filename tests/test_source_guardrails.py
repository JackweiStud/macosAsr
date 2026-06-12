from __future__ import annotations

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class SourceGuardrailTests(unittest.TestCase):
    def test_asr_model_presets_do_not_include_machine_local_paths(self) -> None:
        source = (ROOT / "MacApp/macosAsrApp/AppConfig.swift").read_text()

        self.assertNotIn("/Users/", source)
        self.assertIn('case qwen17B = "mlx-community/Qwen3-ASR-1.7B-8bit"', source)
        self.assertIn('return "Qwen3-ASR 1.7B"', source)
        self.assertNotIn("qwen17BLocal", source)

    def test_daemon_shutdown_has_bounded_wait_and_force_kill_fallback(self) -> None:
        source = (ROOT / "MacApp/macosAsrApp/DaemonManager.swift").read_text()
        shutdown = source.split("func shutdown()", 1)[1].split("func notifySessionStoppedFromDaemon", 1)[0]

        self.assertNotIn("waitUntilExit()", shutdown)
        self.assertIn("Date().addingTimeInterval(3.0)", shutdown)
        self.assertIn("proc.terminate()", shutdown)
        self.assertIn("SIGKILL", shutdown)


if __name__ == "__main__":
    unittest.main()
