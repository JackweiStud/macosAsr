"""ASR configuration — replaces argparse.Namespace from ASR-QWEN."""

from __future__ import annotations

from dataclasses import dataclass


@dataclass
class AsrConfig:
    """Runtime ASR / VAD parameters (SDD §3.5 defaults)."""

    # --- 模型与上下文 ---
    model: str = "mlx-community/Qwen3-ASR-0.6B-8bit"  # MLX / HuggingFace 模型 ID
    language: str = "Chinese"  # 识别语言
    system_prompt: str = ""  # 场景提示；可再拼上一句 final 作为前文
    previous_final_context_enabled: bool = True  # 是否把上一句 final 写入 system_prompt
    previous_final_context_chars: int = 120  # 前文截取字数
    final_audio_trim_enabled: bool = True  # final 推理前是否裁掉句尾静音
    final_trailing_silence_keep_seconds: float = 0.30  # 裁剪后保留的尾部静音
    sample_rate: int = 16_000  # 采样率（Hz）
    device: int | None = None  # 麦克风设备 index；None 用系统默认

    # --- 采集与 partial / 长句滚动 ---
    input_block_seconds: float = 0.02  # 麦克风每次读块时长
    partial_interval_seconds: float = 0.5  # live 刷新间隔；可用 MACOSASR_PARTIAL_INTERVAL 覆盖
    partial_min_audio_seconds: float = 0.60  # 发出 partial 所需最短音频
    # 单句音频上限（默认开启滚动）：到期先 final 再新开一句，避免长句停更。
    # 0 表示不滚动、也不限制 partial 全量重跑（仅调试用）。
    partial_max_audio_seconds: float = 8.0
    # 最短滚动时长。与上限同为 8s：8 秒前不因短换气切句。
    partial_roll_min_seconds: float = 8.0
    # 到期时若已有这么长静音，在静音处切；否则硬切。0.40s 避免把换气当成切点。
    partial_roll_silence_seconds: float = 0.40

    # --- VAD ---
    vad_rms_threshold: float = 0.0  # 0 表示启动时由噪声校准覆盖
    vad_end_silence_seconds: float = 1.50  # 判定句末所需静音
    vad_start_speech_seconds: float = 0.20  # 判定句首所需连续语音
    vad_min_utterance_seconds: float = 0.60  # 最短有效 utterance，过短丢弃
    vad_pre_roll_seconds: float = 0.50  # 句首预卷，避免吞掉开头
    vad_soft_max_utterance_seconds: float = 12.0  # 软上限；超时后可用较短静音提前断句
    vad_soft_break_silence_seconds: float = 0.50  # 软断句所需静音
    vad_max_utterance_seconds: float = 20.0  # 硬上限，强制 flush

    # --- 噪声校准 ---
    noise_calibration_seconds: float = 3.0  # 启动时校准时长
    noise_multiplier: float = 3.0  # 阈值 = RMS × multiplier + margin
    noise_margin: float = 0.003  # 绝对余量
    noise_max_threshold: float = 0.05  # 阈值上限；防止嘈杂校准环境屏蔽正常语音

    # --- 推理与过滤 ---
    stream_chunk_duration: float = 1200.0  # mlx_audio 流式分块时长（秒）；很大则整段一次
    stream_min_chunk_duration: float = 1.0  # 最小分块时长
    warmup_enabled: bool = True  # 启动时用静音跑一次推理预热
    warmup_audio_seconds: float = 1.0  # 预热音频时长
    min_final_chars: int = 2  # final 最短字符数，过短丢弃
    filter_fillers: bool = True  # 是否过滤「嗯/啊」等填充词

    def log_summary(self) -> str:
        return (
            f"model={self.model} "
            f"language={self.language} "
            f"context_chars={len(self.system_prompt)} "
            f"previous_final_context={self.previous_final_context_enabled} "
            f"previous_final_context_chars={self.previous_final_context_chars} "
            f"final_audio_trim={self.final_audio_trim_enabled} "
            f"final_trailing_silence_keep={self.final_trailing_silence_keep_seconds:.2f}s "
            f"sample_rate={self.sample_rate} "
            f"device={self.device} "
            f"input_block={self.input_block_seconds:.2f}s "
            f"partial_interval={self.partial_interval_seconds:.2f}s "
            f"partial_min_audio={self.partial_min_audio_seconds:.2f}s "
            f"partial_max_audio={self.partial_max_audio_seconds:.2f}s "
            f"partial_roll_min={self.partial_roll_min_seconds:.2f}s "
            f"partial_roll_silence={self.partial_roll_silence_seconds:.2f}s "
            f"vad_rms_threshold={self.vad_rms_threshold:.4f} "
            f"vad_end_silence={self.vad_end_silence_seconds:.2f}s "
            f"vad_start_speech={self.vad_start_speech_seconds:.2f}s "
            f"vad_min_utterance={self.vad_min_utterance_seconds:.2f}s "
            f"vad_pre_roll={self.vad_pre_roll_seconds:.2f}s "
            f"vad_soft_max_utterance={self.vad_soft_max_utterance_seconds:.2f}s "
            f"vad_soft_break_silence={self.vad_soft_break_silence_seconds:.2f}s "
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
