"""Entry: python -m asr_daemon"""

from __future__ import annotations

import argparse
import logging
import signal
import sys
from pathlib import Path

from asr.config import AsrConfig
from asr.run_utils import DEFAULT_DAEMON_LOG, PROJECT_ROOT, setup_tee
from asr_daemon.server import DaemonServer


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        prog="asr_daemon",
        description="macosAsr ASR daemon — Unix socket JSON-lines IPC",
    )
    parser.add_argument(
        "--socket",
        type=Path,
        default=PROJECT_ROOT / "run" / "macosasr.sock",
        help="Unix socket path (default: run/macosasr.sock)",
    )
    parser.add_argument("--model", default=None, help="Override MLX model name")
    parser.add_argument("--language", default=None, help="Default language hint")
    parser.add_argument(
        "--log-file",
        type=Path,
        default=DEFAULT_DAEMON_LOG,
        help="Tee stdout/stderr to this log file",
    )
    parser.add_argument(
        "--skip-model",
        action="store_true",
        help="Start socket only without loading MLX (debug)",
    )
    parser.add_argument("-v", "--verbose", action="store_true", help="DEBUG logging")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    setup_tee(args.log_file)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )

    config = AsrConfig()
    if args.model:
        config.model = args.model
    if args.language:
        config.language = args.language

    server = DaemonServer(args.socket, config, skip_model=args.skip_model)

    def _shutdown(*_sig):  # pragma: no cover
        logging.info("shutdown signal received")
        server.stop()
        sys.exit(0)

    signal.signal(signal.SIGINT, _shutdown)
    signal.signal(signal.SIGTERM, _shutdown)

    try:
        server.start()
    except KeyboardInterrupt:
        server.stop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
