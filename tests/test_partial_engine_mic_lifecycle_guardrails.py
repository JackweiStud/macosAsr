from __future__ import annotations

from pathlib import Path
import unittest
from unittest.mock import patch

from asr.config import AsrConfig
import asr.partial_engine as partial_engine
from asr.partial_engine import PartialEngine

ROOT = Path(__file__).resolve().parents[1]


class _Callback:
    def on_partial(self, utterance_id: int, text: str) -> None:
        pass

    def on_final(self, utterance_id: int, text: str) -> None:
        pass

    def on_filtered(self, utterance_id: int, text: str, reason: str) -> None:
        pass

    def on_error(self, message: str) -> None:
        pass


class _FakeStream:
    def __init__(self, **kwargs) -> None:
        self.kwargs = kwargs
        self.started = False
        self.stopped = False
        self.closed = False

    def start(self) -> None:
        self.started = True

    def stop(self) -> None:
        self.stopped = True

    def close(self) -> None:
        self.closed = True


class _FakeSoundDevice:
    def __init__(self) -> None:
        self.streams: list[_FakeStream] = []

    def InputStream(self, **kwargs) -> _FakeStream:
        stream = _FakeStream(**kwargs)
        self.streams.append(stream)
        return stream


class PartialEngineMicLifecycleGuardrailTests(unittest.TestCase):
    def test_partial_engine_can_close_mic_after_calibration_and_reopen_for_sessions(self) -> None:
        source = (ROOT / "asr/partial_engine.py").read_text()

        self.assertIn("def start_recording(self) -> None", source)
        self.assertIn("def stop_recording(self) -> None", source)
        self.assertIn("def _open_mic_stream(self) -> None", source)
        self.assertIn("def _close_mic_stream(self) -> None", source)
        self.assertIn("self._close_mic_stream()", source.split("self._calibrate_noise(cfg)", 1)[1])

    def test_status_payload_exposes_recording_state_for_privacy_debugging(self) -> None:
        partial_engine = (ROOT / "asr/partial_engine.py").read_text()
        session = (ROOT / "asr_daemon/session.py").read_text()

        self.assertIn("def recording_active(self) -> bool", partial_engine)
        self.assertIn('"recording_active": self._engine.recording_active', session)

    def test_open_and_close_mic_stream_updates_recording_state(self) -> None:
        fake_sd = _FakeSoundDevice()
        engine = PartialEngine(AsrConfig(noise_calibration_seconds=0), _Callback())

        with (
            patch.object(partial_engine, "sd", fake_sd),
            patch.object(partial_engine, "require_runtime_dependencies"),
        ):
            engine._configure_pre_roll()
            engine._open_mic_stream()
            self.assertTrue(engine.recording_active)
            self.assertEqual(len(fake_sd.streams), 1)
            self.assertTrue(fake_sd.streams[0].started)

            engine._close_mic_stream()
            self.assertFalse(engine.recording_active)
            self.assertTrue(fake_sd.streams[0].stopped)
            self.assertTrue(fake_sd.streams[0].closed)


if __name__ == "__main__":
    unittest.main()
