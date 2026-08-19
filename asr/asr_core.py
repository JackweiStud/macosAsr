"""Qwen3-ASR core — trimmed from ASR-QWEN Script/asr_stream.py."""

from __future__ import annotations

import dataclasses
import sys
import time
from typing import Optional

import numpy as np

from asr.config import AsrConfig

try:
    import sounddevice as sd
except ImportError:  # pragma: no cover
    sd = None

try:
    from mlx_audio.stt import load as load_asr_model
except ImportError as exc:  # pragma: no cover
    load_asr_model = None
    _IMPORT_ERROR = exc
else:
    _IMPORT_ERROR = None

FILLER_WORDS = {
    "嗯",
    "嗯嗯",
    "啊",
    "哦",
    "额",
    "呃",
    "唉",
    "哎",
    "咳",
    "咳咳",
    "哈",
    "诶",
}


@dataclasses.dataclass
class AudioBlock:
    samples: np.ndarray
    captured_at: float


def require_runtime_dependencies() -> None:
    if _IMPORT_ERROR is not None:
        raise RuntimeError(
            "mlx_audio is not installed or failed to import: "
            f"{_IMPORT_ERROR}. Install with: pip install -r requirements.txt"
        )
    if sd is None:
        raise RuntimeError(
            "sounddevice is not installed. Install with: pip install -r requirements.txt"
        )


def list_devices() -> None:
    require_runtime_dependencies()
    assert sd is not None
    print(sd.query_devices())


def load_model(model_name: str):
    if load_asr_model is None:
        raise RuntimeError(
            "mlx_audio is not installed or failed to import.\n"
            "Install with: pip install -r requirements.txt"
        )
    print(f"Loading model: {model_name}")
    return load_asr_model(model_name)


def current_rss_mib() -> Optional[float]:
    try:
        import resource
    except ImportError:
        return None
    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    if sys.platform == "darwin":
        return rss / (1024.0 * 1024.0)
    return rss / 1024.0


def normalize_text(text: str) -> str:
    return " ".join(text.strip().split())


def compact_text(text: str) -> str:
    punctuation = " ,.?!;:'\"()[]{}<>-_/\\|`~@#$%^&*+=，。！？；：、“”‘’（）【】《》"
    return "".join(ch for ch in text if not ch.isspace() and ch not in punctuation)


def should_drop_final_text(text: str, config: AsrConfig) -> bool:
    normalized = normalize_text(text)
    compact = compact_text(normalized)
    if not compact:
        return True
    if len(compact) < config.min_final_chars:
        return True
    if config.filter_fillers and compact in FILLER_WORDS:
        return True
    return False


def audio_rms(samples: np.ndarray) -> float:
    if len(samples) == 0:
        return 0.0
    samples = np.asarray(samples, dtype=np.float32)
    return float(np.sqrt(np.mean(np.square(samples), dtype=np.float32)))


def stream_utterance_text(model, blocks: list[AudioBlock], config: AsrConfig) -> str:
    if not blocks:
        return ""
    audio_wave = np.concatenate([block.samples for block in blocks]).astype(np.float32, copy=False)
    pieces: list[str] = []
    for result in model.stream_transcribe(
        audio_wave,
        language=config.language,
        system_prompt=config.system_prompt or None,
        chunk_duration=config.stream_chunk_duration,
        min_chunk_duration=config.stream_min_chunk_duration,
        verbose=False,
    ):
        text = getattr(result, "text", None)
        if text is None:
            text = str(result)
        text = normalize_text(text)
        if text:
            pieces.append(text)
    return normalize_text("".join(pieces))


def generate_utterance_text(model, blocks: list[AudioBlock], config: AsrConfig) -> str:
    if not blocks:
        return ""
    audio_wave = np.concatenate([block.samples for block in blocks]).astype(np.float32, copy=False)
    result = model.generate(
        audio_wave,
        language=config.language,
        system_prompt=config.system_prompt or None,
        chunk_duration=config.stream_chunk_duration,
        min_chunk_duration=config.stream_min_chunk_duration,
        verbose=False,
    )
    text = getattr(result, "text", None)
    if text is None:
        text = str(result)
    return normalize_text(text)


def warm_up_asr_model(model, config: AsrConfig) -> dict[str, float]:
    sample_count = max(1, int(config.sample_rate * config.warmup_audio_seconds))
    block = AudioBlock(
        samples=np.zeros(sample_count, dtype=np.float32),
        captured_at=time.perf_counter(),
    )

    stream_start = time.perf_counter()
    stream_utterance_text(model, [block], config)
    stream_ms = (time.perf_counter() - stream_start) * 1000.0

    generate_start = time.perf_counter()
    generate_utterance_text(model, [block], config)
    generate_ms = (time.perf_counter() - generate_start) * 1000.0

    return {
        "stream_ms": stream_ms,
        "generate_ms": generate_ms,
    }
