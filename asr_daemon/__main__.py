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


def _env_flag_enabled(value: str) -> bool:
    return value.strip().lower() in {"1", "true", "yes", "on"}


def apply_env_overrides(config: AsrConfig, environ: dict[str, str]) -> None:
    context_env = environ.get("MACOSASR_CONTEXT")
    if context_env is not None:
        config.system_prompt = context_env.strip()

    previous_final_context_env = environ.get("MACOSASR_PREVIOUS_FINAL_CONTEXT")
    if previous_final_context_env is not None:
        config.previous_final_context_enabled = _env_flag_enabled(previous_final_context_env)

    previous_final_context_chars_env = environ.get("MACOSASR_PREVIOUS_FINAL_CONTEXT_CHARS")
    if previous_final_context_chars_env:
        config.previous_final_context_chars = max(0, int(previous_final_context_chars_env))

    final_audio_trim_env = environ.get("MACOSASR_FINAL_AUDIO_TRIM")
    if final_audio_trim_env is not None:
        config.final_audio_trim_enabled = _env_flag_enabled(final_audio_trim_env)

    final_trailing_silence_keep_env = environ.get("MACOSASR_FINAL_TRAILING_SILENCE_KEEP")
    if final_trailing_silence_keep_env:
        config.final_trailing_silence_keep_seconds = max(0.0, float(final_trailing_silence_keep_env))

    partial_env = environ.get("MACOSASR_PARTIAL_INTERVAL")
    if partial_env:
        config.partial_interval_seconds = float(partial_env)

    partial_max_env = environ.get("MACOSASR_PARTIAL_MAX_AUDIO")
    if partial_max_env:
        config.partial_max_audio_seconds = max(0.0, float(partial_max_env))

    partial_roll_min_env = environ.get("MACOSASR_PARTIAL_ROLL_MIN")
    if partial_roll_min_env:
        config.partial_roll_min_seconds = max(0.0, float(partial_roll_min_env))

    partial_roll_silence_env = environ.get("MACOSASR_PARTIAL_ROLL_SILENCE")
    if partial_roll_silence_env:
        config.partial_roll_silence_seconds = max(0.0, float(partial_roll_silence_env))

    vad_end_env = environ.get("MACOSASR_VAD_END_SILENCE")
    if vad_end_env:
        config.vad_end_silence_seconds = float(vad_end_env)

    vad_soft_max_env = environ.get("MACOSASR_VAD_SOFT_MAX_UTTERANCE")
    if vad_soft_max_env:
        config.vad_soft_max_utterance_seconds = max(0.0, float(vad_soft_max_env))

    vad_soft_break_env = environ.get("MACOSASR_VAD_SOFT_BREAK_SILENCE")
    if vad_soft_break_env:
        config.vad_soft_break_silence_seconds = max(0.0, float(vad_soft_break_env))


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

    def _log_filter(line: str) -> bool:
        """跳过模型下载进度条等 stdout 噪音，仍写入 log 文件。"""
        noisy = (
            "Fetching ",
            "Download complete",
            "Downloading (",
            "Loading model:",
            "|########",
            "\r",
        )
        return not any(token in line for token in noisy)

    setup_tee(args.log_file, console_filter=_log_filter)

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    # 减少 daemon.log 噪音：不记录 HTTP 请求与模型下载进度条
    logging.getLogger("httpx").setLevel(logging.WARNING)
    logging.getLogger("httpcore").setLevel(logging.WARNING)
    logging.getLogger("huggingface_hub").setLevel(logging.WARNING)
    logging.getLogger("filelock").setLevel(logging.WARNING)

    import os
    os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
    os.environ.setdefault("TQDM_DISABLE", "1")

    config = AsrConfig()
    if args.model:
        config.model = args.model
    if args.language:
        config.language = args.language
    apply_env_overrides(config, os.environ)

    logging.info("ASR config %s", config.log_summary())

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
