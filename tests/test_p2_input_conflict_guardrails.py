from __future__ import annotations

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class P2InputConflictGuardrailTests(unittest.TestCase):
    def test_injection_state_machine_can_discard_pending_without_backspace(self) -> None:
        source = (ROOT / "MacApp/macosAsrApp/InjectionStateMachine.swift").read_text()

        self.assertIn("func onUserInputInterrupted()", source)
        self.assertIn("applyUserInputInterrupted", source)
        interrupt_body = source.split("private func applyUserInputInterrupted", 1)[1].split(
            "private func", 1
        )[0]
        self.assertIn('pendingText = ""', interrupt_body)
        self.assertNotIn("injector.backspace", interrupt_body)

    def test_global_hotkey_monitor_reports_user_input_and_ignores_own_events(self) -> None:
        monitor = (ROOT / "MacApp/macosAsrApp/GlobalHotkeyMonitor.swift").read_text()
        injector = (ROOT / "MacApp/macosAsrApp/TextInjector.swift").read_text()
        app_delegate = (ROOT / "MacApp/macosAsrApp/AppDelegate.swift").read_text()
        live_dictation = (ROOT / "MacApp/macosAsrApp/LiveDictationController.swift").read_text()

        self.assertIn("var onUserInput: (() -> Void)?", monitor)
        self.assertIn("leftMouseDown", monitor)
        self.assertIn("rightMouseDown", monitor)
        self.assertIn("otherMouseDown", monitor)
        self.assertIn("isOwnInjectedEvent", monitor)
        self.assertIn("eventSourceUserData", monitor)
        self.assertIn("InjectionEventMarker.userData", monitor)
        self.assertIn("onUserInput?()", monitor)

        self.assertIn("enum InjectionEventMarker", injector)
        self.assertIn("setIntegerValueField(.eventSourceUserData", injector)

        self.assertIn("hotkeyMonitor.onUserInput", app_delegate)
        self.assertIn("notifyUserInputInterrupted", live_dictation)


if __name__ == "__main__":
    unittest.main()
