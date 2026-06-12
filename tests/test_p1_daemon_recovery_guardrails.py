from __future__ import annotations

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


class P1DaemonRecoveryGuardrailTests(unittest.TestCase):
    def test_daemon_client_reports_send_and_read_failures(self) -> None:
        source = (ROOT / "MacApp/macosAsrApp/DaemonClient.swift").read_text()

        self.assertIn("var onConnectionFailure: ((Error) -> Void)?", source)
        self.assertIn("completion: ((Result<Void, Error>) -> Void)? = nil", source)
        self.assertIn("reportConnectionFailure", source)
        self.assertRegex(source, r"writeResult\s*<\s*0")
        self.assertRegex(source, r"writeResult\s*!=\s*lineByteCount")
        self.assertIn("SO_NOSIGPIPE", source)

    def test_daemon_manager_moves_to_error_when_daemon_exits_or_socket_breaks(self) -> None:
        source = (ROOT / "MacApp/macosAsrApp/DaemonManager.swift").read_text()

        self.assertIn("client.onConnectionFailure", source)
        self.assertIn("terminationHandler", source)
        self.assertIn("handleDaemonTermination", source)
        self.assertIn("markDaemonFailed", source)
        self.assertIn("consecutiveRestartFailures", source)
        self.assertIn("maxRestartFailures", source)
        self.assertIn("removeStaleSocket()", source)

        failure_handler = source.split("private func markDaemonFailed", 1)[1].split(
            "private func sendSessionStart", 1
        )[0]
        self.assertIn("proc.terminate()", failure_handler)

    def test_error_state_can_trigger_respawn_instead_of_silent_return(self) -> None:
        source = (ROOT / "MacApp/macosAsrApp/AppDelegate.swift").read_text()
        toggle = source.split("@objc private func toggleLiveDictation()", 1)[1].split("private func requireAccessibility", 1)[0]
        error_state = re.search(r"case \.error:[\s\S]*?(?=\n\s*case|\n\s*default:|\n\s*})", toggle)

        self.assertIsNotNone(error_state)
        assert error_state is not None
        self.assertIn("DaemonManager.shared.warmUp()", error_state.group(0))


if __name__ == "__main__":
    unittest.main()
