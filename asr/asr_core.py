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


CONTEXT_PREFIX_MARKER = "前文："
HOTWORDS_PREFIX_MARKER = "常用术语："
_PROMPT_ECHO_MARKERS = ("当前窗口：", "光标前文：", "常用术语：", "前文：")


def is_prompt_echo_hallucination(text: str, system_prompt: str, audio_seconds: float) -> bool:
    """Detect Qwen3-ASR hallucinations that echo system_prompt on brief noise/silence."""
    if not text or not system_prompt:
        return False
    norm_text = normalize_text(text)
    norm_prompt = normalize_text(system_prompt)
    if not norm_text or not norm_prompt:
        return False

    matched_markers = 0
    for marker in _PROMPT_ECHO_MARKERS:
        if marker in norm_prompt and marker in norm_text:
            matched_markers += 1
            prompt_tail = compact_text(norm_prompt.split(marker, 1)[1])[:6]
            text_tail = compact_text(norm_text.split(marker, 1)[1])
            if len(prompt_tail) >= 3 and text_tail.startswith(prompt_tail[:3]):
                return True
    if matched_markers >= 2:
        return True

    compact_out = compact_text(norm_text)
    compact_prompt = compact_text(norm_prompt)
    if audio_seconds <= 2.5 and len(compact_out) >= 10 and compact_out in compact_prompt:
        return True
    return False


def normalize_text(text: str) -> str:
    return " ".join(text.strip().split())


def format_hotwords_prompt(raw_hotwords: str, *, max_terms: int = 80, max_chars: int = 600) -> str:
    """Normalize user hotwords (comma/newline-separated) into a Qwen3-ASR context prompt."""
    stripped = raw_hotwords.strip()
    if not stripped:
        return ""
    if stripped.startswith((HOTWORDS_PREFIX_MARKER, "场景：")):
        return stripped[:max_chars].strip()

    separators = "\n\r,，、;；"
    terms: list[str] = []
    seen: set[str] = set()
    buf: list[str] = []
    for ch in stripped:
        if ch in separators:
            token = normalize_text("".join(buf))
            buf.clear()
            if token and token.lower() not in seen:
                seen.add(token.lower())
                terms.append(token)
        else:
            buf.append(ch)
    if buf:
        token = normalize_text("".join(buf))
        if token and token.lower() not in seen:
            seen.add(token.lower())
            terms.append(token)

    if not terms:
        return ""
    selected: list[str] = []
    total_len = len(HOTWORDS_PREFIX_MARKER)
    for term in terms[:max_terms]:
        extra = len(term) + (2 if selected else 0)
        if total_len + extra > max_chars:
            break
        selected.append(term)
        total_len += extra
    if not selected:
        return ""
    return f"{HOTWORDS_PREFIX_MARKER}{', '.join(selected)}"


def _join_context_fragments(left: str, right: str) -> str:
    left = normalize_text(left)
    right = normalize_text(right)
    if not left:
        return right
    if not right:
        return left
    if left[-1].isascii() and left[-1].isalnum() and right[0].isascii() and right[0].isalnum():
        return f"{left} {right}"
    return f"{left}{right}"


def merge_context_system_prompt(system_prompt: str, committed_text: str, max_chars: int) -> str:
    """Append intra-utterance confirmed prefix into the trailing '前文：' slot."""
    limit = max(0, max_chars)
    committed_norm = normalize_text(committed_text)
    if limit <= 0 or not committed_norm:
        return system_prompt

    base_prompt = system_prompt
    prev_context = ""
    newline_marker = f"\n{CONTEXT_PREFIX_MARKER}"
    if newline_marker in system_prompt:
        base_prompt, prev_context = system_prompt.rsplit(newline_marker, 1)
    elif system_prompt.startswith(CONTEXT_PREFIX_MARKER):
        base_prompt = ""
        prev_context = system_prompt[len(CONTEXT_PREFIX_MARKER):]

    combined = _join_context_fragments(prev_context, committed_norm)[-limit:]
    if not combined:
        return base_prompt
    if base_prompt:
        return f"{base_prompt}\n{CONTEXT_PREFIX_MARKER}{combined}"
    return f"{CONTEXT_PREFIX_MARKER}{combined}"


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
    # Real Qwen3-ASR models expose _tokenizer + generate; decoding the full token
    # sequence at once preserves BPE leading spaces and multi-token UTF-8 bytes.
    if hasattr(model, "_tokenizer") and hasattr(model, "generate"):
        return generate_utterance_text(model, blocks, config)
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
