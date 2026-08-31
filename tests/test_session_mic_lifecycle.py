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


class _BoomEngine(_FakeEngine):
    def start_recording(self) -> None:
        self.calls.append(("start_recording", None))
        raise RuntimeError("Internal PortAudio error [PaErrorCode -9986]")


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

    def test_session_start_does_not_keep_session_when_mic_open_fails(self) -> None:
        engine = _BoomEngine()
        controller = SessionController(engine, AsrConfig(), lambda event: None)  # type: ignore[arg-type]

        with self.assertRaises(RuntimeError):
            controller.start_session()

        self.assertIsNone(controller.session_id)
        self.assertFalse(engine.is_listening())
        self.assertEqual(engine.calls, [("start_recording", None)])

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

    def test_previous_final_context_updates_next_prompt_when_enabled(self) -> None:
        engine = _FakeEngine()
        config = AsrConfig(
            system_prompt="场景：软件开发。",
            previous_final_context_enabled=True,
        )
        controller = SessionController(engine, config, lambda event: None)  # type: ignore[arg-type]

        controller.start_session()
        controller.on_partial(1, "Web Socket")
        self.assertEqual(config.system_prompt, "场景：软件开发。")

        controller.on_final(1, "通过   WebSocket  推送异步消息。")

        self.assertEqual(config.system_prompt, "场景：软件开发。\n前文：通过 WebSocket 推送异步消息。")

    def test_previous_final_context_does_not_update_when_disabled(self) -> None:
        engine = _FakeEngine()
        config = AsrConfig(
            system_prompt="场景：软件开发。",
            previous_final_context_enabled=False,
        )
        controller = SessionController(engine, config, lambda event: None)  # type: ignore[arg-type]

        controller.start_session()
        controller.on_final(1, "通过 WebSocket 推送异步消息。")

        self.assertEqual(config.system_prompt, "场景：软件开发。")

    def test_previous_final_context_truncates_and_resets_after_session(self) -> None:
        engine = _FakeEngine()
        config = AsrConfig(
            previous_final_context_enabled=True,
            previous_final_context_chars=4,
        )
        controller = SessionController(engine, config, lambda event: None)  # type: ignore[arg-type]

        controller.start_session()
        controller.on_final(1, "abcdef")
        self.assertEqual(config.system_prompt, "前文：cdef")

        controller.stop_session()

        self.assertEqual(config.system_prompt, "")


if __name__ == "__main__":
    unittest.main()
