from __future__ import annotations

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]


class LiveDictationStopGuardrailTests(unittest.TestCase):
    def test_stop_keeps_input_conflict_protection_until_daemon_session_stopped(self) -> None:
        source = (ROOT / "MacApp/macosAsrApp/LiveDictationController.swift").read_text()

        self.assertIn("enum DictationRunState", source)
        self.assertIn("case stoppingAwaitingFinal", source)
        self.assertIn("runState = .stoppingAwaitingFinal", source)

        interrupt_body = source.split("func notifyUserInputInterrupted()", 1)[1].split(
            "private func handle", 1
        )[0]
        self.assertNotIn("guard isListening else { return }", interrupt_body)
        self.assertIn("case .dictating, .stoppingAwaitingFinal", interrupt_body)
        self.assertIn("stateMachine.onUserInputInterrupted()", interrupt_body)
        self.assertIn("dropFinalAfterUserInput = true", interrupt_body)

        final_case = source.split('case "final":', 1)[1].split('case "filtered":', 1)[0]
        self.assertIn("dropFinalAfterUserInput", final_case)
        self.assertIn("late_final_dropped_after_user_input", final_case)
        self.assertIn("stateMachine.onFinal(text)", final_case)


if __name__ == "__main__":
    unittest.main()
