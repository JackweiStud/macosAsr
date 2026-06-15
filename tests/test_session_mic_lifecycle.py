from __future__ import annotations

import unittest

from asr.config import AsrConfig
from asr_daemon.session import SessionController


class _FakeEngine:
    calibrated = True
    warmed_up = True

    def __init__(self) -> None:
        self.calls: list[tuple[str, bool | None]] = []
        self._listening = False

    def start_recording(self) -> None:
        self.calls.append(("start_recording", None))

    def stop_recording(self) -> None:
        self.calls.append(("stop_recording", None))

    def set_listening(self, listening: bool) -> None:
        self._listening = listening
        self.calls.append(("set_listening", listening))

    def is_listening(self) -> bool:
        return self._listening

    def flush_on_stop(self) -> None:
        self.calls.append(("flush_on_stop", None))


class SessionMicLifecycleTests(unittest.TestCase):
    def test_session_start_opens_mic_before_listening(self) -> None:
        engine = _FakeEngine()
        controller = SessionController(engine, AsrConfig(), lambda event: None)  # type: ignore[arg-type]

        controller.start_session()

        self.assertEqual(
            engine.calls[:2],
            [
                ("start_recording", None),
                ("set_listening", True),
            ],
        )

    def test_session_stop_flushes_then_closes_mic(self) -> None:
        engine = _FakeEngine()
        controller = SessionController(engine, AsrConfig(), lambda event: None)  # type: ignore[arg-type]

        controller.start_session()
        controller.stop_session()

        self.assertEqual(
            engine.calls,
            [
                ("start_recording", None),
                ("set_listening", True),
                ("set_listening", False),
                ("flush_on_stop", None),
                ("stop_recording", None),
            ],
        )


if __name__ == "__main__":
    unittest.main()
