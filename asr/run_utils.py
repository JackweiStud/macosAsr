"""Tee stdout/stderr to project log/ — adapted from ASR-QWEN Script/run_utils.py."""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import sys
from typing import Callable, TextIO

PROJECT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_DAEMON_LOG = PROJECT_ROOT / "log" / "daemon.log"
DEFAULT_ASR_LOG = PROJECT_ROOT / "log" / "asr.log"


@dataclass
class TeeStream:
    console: TextIO
    file: TextIO
    console_debug: bool = True
    console_filter: Callable[[str], bool] | None = None
    last_console_write_allowed: bool = False

    def write(self, data: str) -> int:
        if self.console_debug or self.console_filter is None:
            self.console.write(data)
        else:
            self._write_filtered_to_console(data)
        self.file.write(data)
        return len(data)

    def write_public(self, data: str) -> int:
        self.console.write(data)
        self.file.write(data)
        self.last_console_write_allowed = not data.endswith(("\n", "\r"))
        return len(data)

    def _write_filtered_to_console(self, data: str) -> None:
        if not data:
            return
        if not data.strip():
            if self.last_console_write_allowed:
                self.console.write(data)
            if "\n" in data or "\r" in data:
                self.last_console_write_allowed = False
            return
        for part in data.splitlines(keepends=True):
            if self.console_filter(part):
                self.console.write(part)
                self.last_console_write_allowed = not part.endswith(("\n", "\r"))
            else:
                self.last_console_write_allowed = False

    def flush(self) -> None:
        self.console.flush()
        self.file.flush()

    def isatty(self) -> bool:
        return self.console.isatty()

    def fileno(self) -> int:
        return self.console.fileno()


def setup_tee(
    log_file: Path | None,
    *,
    console_debug: bool = True,
    console_filter: Callable[[str], bool] | None = None,
) -> None:
    if log_file is None:
        return
    log_file = log_file.expanduser()
    if not log_file.is_absolute():
        log_file = PROJECT_ROOT / log_file
    log_file = log_file.resolve()
    log_file.parent.mkdir(parents=True, exist_ok=True)
    file_handle = log_file.open("a", encoding="utf-8")
    sys.stdout = TeeStream(sys.stdout, file_handle, console_debug, console_filter)  # type: ignore[assignment]
    sys.stderr = TeeStream(sys.stderr, file_handle, console_debug, console_filter)  # type: ignore[assignment]


def write_public(data: str, *, stream: TextIO | None = None, flush: bool = False) -> None:
    target = stream or sys.stdout
    writer = getattr(target, "write_public", None)
    if callable(writer):
        writer(data)
    else:
        target.write(data)
    if flush:
        target.flush()
