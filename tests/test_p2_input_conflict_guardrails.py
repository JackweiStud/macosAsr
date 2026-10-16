from __future__ import annotations

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


class P2InputConflictGuardrailTests(unittest.TestCase):
    def test_user_input_interrupt_exposes_cutoff_and_cancellation_session(self) -> None:
        source = (ROOT / "MacApp/macosAsrApp/InjectionStateMachine.swift").read_text()

        # Behavior (late events, queued/in-flight writes, stop and next utterance)
        # is exercised by the production Swift state-machine self-test.
        self.assertRegex(source, r"func onUserInputInterrupted\(at(?: \w+)?: TimeInterval")
        self.assertIn("Date().timeIntervalSince1970", source)
        self.assertRegex(
            source,
            r"func onUserInputInterrupted\([\s\S]*?\)\s*->\s*String\?",
        )
        match = re.search(
            r"func onUserInputInterrupted\([\s\S]*?\n    \}", source
        )
        self.assertIsNotNone(match)
        assert match is not None
        self.assertNotIn("injector.backspace", match.group())
        self.assertNotIn("injector.typeText", match.group())

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
