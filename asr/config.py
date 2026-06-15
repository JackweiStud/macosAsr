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
    partial_interval_seconds: float = 0.5   # live 感与推理开销折中；可用 MACOSASR_PARTIAL_INTERVAL 覆盖
    partial_min_audio_seconds: float = 0.60
    partial_max_audio_seconds: float = 8.0

    vad_rms_threshold: float = 0.0
    vad_end_silence_seconds: float = 1.50
    vad_relative_silence_ratio: float = 0.35
    vad_start_speech_seconds: float = 0.20
    vad_min_utterance_seconds: float = 0.60
    vad_pre_roll_seconds: float = 0.50
    vad_max_utterance_seconds: float = 20.0

    noise_calibration_seconds: float = 3.0
    noise_multiplier: float = 3.0
    noise_margin: float = 0.003
    noise_max_threshold: float = 0.05   # 阈值上限；防止嘈杂校准环境屏蔽正常语音

    stream_chunk_duration: float = 1200.0
    stream_min_chunk_duration: float = 1.0
    warmup_enabled: bool = True
    warmup_audio_seconds: float = 1.0
    min_final_chars: int = 2
    filter_fillers: bool = True

    def log_summary(self) -> str:
        return (
            f"model={self.model} "
            f"language={self.language} "
            f"sample_rate={self.sample_rate} "
            f"device={self.device} "
            f"input_block={self.input_block_seconds:.2f}s "
            f"partial_interval={self.partial_interval_seconds:.2f}s "
            f"partial_min_audio={self.partial_min_audio_seconds:.2f}s "
            f"partial_max_audio={self.partial_max_audio_seconds:.2f}s "
            f"vad_rms_threshold={self.vad_rms_threshold:.4f} "
            f"vad_end_silence={self.vad_end_silence_seconds:.2f}s "
            f"vad_relative_silence_ratio={self.vad_relative_silence_ratio:.2f} "
            f"vad_start_speech={self.vad_start_speech_seconds:.2f}s "
            f"vad_min_utterance={self.vad_min_utterance_seconds:.2f}s "
            f"vad_pre_roll={self.vad_pre_roll_seconds:.2f}s "
            f"vad_max_utterance={self.vad_max_utterance_seconds:.2f}s "
            f"noise_calibration={self.noise_calibration_seconds:.2f}s "
            f"noise_multiplier={self.noise_multiplier:.2f} "
            f"noise_margin={self.noise_margin:.4f} "
            f"noise_max_threshold={self.noise_max_threshold:.4f} "
            f"stream_chunk_duration={self.stream_chunk_duration:.2f} "
            f"stream_min_chunk_duration={self.stream_min_chunk_duration:.2f} "
            f"warmup_enabled={self.warmup_enabled} "
            f"warmup_audio={self.warmup_audio_seconds:.2f}s "
            f"min_final_chars={self.min_final_chars} "
            f"filter_fillers={self.filter_fillers}"
        )
