from __future__ import annotations

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[1]


class P2InjectionQueueGuardrailTests(unittest.TestCase):
    def test_injection_state_machine_uses_dedicated_serial_queue(self) -> None:
        source = (ROOT / "MacApp/macosAsrApp/InjectionStateMachine.swift").read_text()

        self.assertIn('DispatchQueue(label: "com.macosasr.injection")', source)
        self.assertIn("DispatchSpecificKey", source)
        self.assertIn("injectionQueue.async", source)
        self.assertIn("func runOnInjectionQueue", source)

    def test_public_event_handlers_only_enqueue_work(self) -> None:
        source = (ROOT / "MacApp/macosAsrApp/InjectionStateMachine.swift").read_text()

        for method in ("onPartial", "onFinal", "onFiltered", "onSessionStopped"):
            match = re.search(
                rf"func {method}\([^)]*\) \{{(?P<body>[\s\S]*?)\n    \}}",
                source,
            )
            self.assertIsNotNone(match, method)
            assert match is not None
            body = match.group("body")
            self.assertIn("runOnInjectionQueue", body, method)
            self.assertNotIn("injector.", body, method)

    def test_live_dictation_does_not_dispatch_injection_back_to_main(self) -> None:
        source = (ROOT / "MacApp/macosAsrApp/LiveDictationController.swift").read_text()
        handler = source.split("private func handle(_ event: DaemonEvent)", 1)[1]

        self.assertNotIn("DispatchQueue.main.async", handler)
        self.assertIn("stateMachine.onPartial(text)", handler)
        self.assertIn("stateMachine.onFinal(text)", handler)


if __name__ == "__main__":
    unittest.main()
