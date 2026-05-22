"""ASR configuration — replaces argparse.Namespace from ASR-QWEN."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass
class AsrConfig:
    """Runtime ASR / VAD parameters (SDD §3.5 defaults)."""

    model: str = "mlx-community/Qwen3-ASR-0.6B-8bit"
    language: str = "Chinese"
    sample_rate: int = 16_000
    device: int | None = None

    input_block_seconds: float = 0.02
    partial_interval_seconds: float = 0.25
    partial_min_audio_seconds: float = 0.60

    vad_rms_threshold: float = 0.0
    vad_end_silence_seconds: float = 0.30
    vad_start_speech_seconds: float = 0.20
    vad_min_utterance_seconds: float = 0.60
    vad_pre_roll_seconds: float = 0.50
    vad_max_utterance_seconds: float = 20.0

    noise_calibration_seconds: float = 3.0
    noise_multiplier: float = 3.0
    noise_margin: float = 0.003

    stream_chunk_duration: float = 1200.0
    stream_min_chunk_duration: float = 1.0
    min_final_chars: int = 2
    filter_fillers: bool = True
