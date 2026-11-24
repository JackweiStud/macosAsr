"""Native MLX streaming decoder for Qwen3-ASR.

Exploits two architectural properties of Qwen3-ASR:
1. AudioEncoder applies block-diagonal self-attention in disjoint windows of
   ``n_window_infer`` mel frames (800 frames = 8.0s). Completed 8s blocks
   produce invariant embeddings and are cached across partials.
2. The text decoder accepts an assistant prefix right after ``<asr_text>``.
   Advancing a monotonic ``committed_token_ids`` prefix while keeping the last
   ``unfixed_tokens`` revisable eliminates audio-cut stitching and turns long
   utterance partials into fast parallel prefill + short tail decode.
"""

from __future__ import annotations

import dataclasses
import time
from typing import Any

import numpy as np

from asr.asr_core import AudioBlock, normalize_text
from asr.config import AsrConfig

_EOS_TOKEN_IDS = (151645, 151643)
_STFT_EDGE_MARGIN_FRAMES = 4


@dataclasses.dataclass(frozen=True)
class StreamingStepResult:
    text: str
    prefix_tokens: int
    generated_tokens: int
    cached_blocks: int
    encoded_blocks: int
    elapsed_ms: float


def _unwrap_qwen3_model(model: Any) -> Any | None:
    if model is None:
        return None
    inner = getattr(model, "_model", model)
    required = ("get_audio_features", "_feature_extractor", "_tokenizer", "_build_prompt", "config")
    if not all(hasattr(inner, attr) for attr in required):
        return None
    audio_cfg = getattr(inner.config, "audio_config", None)
    if audio_cfg is None or not hasattr(audio_cfg, "n_window_infer"):
        return None
    return inner


def supports_native_streaming(model: Any) -> bool:
    """Return True when model exposes the MLX Qwen3-ASR internals for block-cached streaming."""
    return _unwrap_qwen3_model(model) is not None


def _trim_safe_prefix_tokens(
    full_tokens: list[int],
    unfixed_tokens: int,
    tokenizer: Any,
    min_len: int,
) -> list[int]:
    """Roll back the unstable tail while avoiding mid-UTF-8 or mid-ASCII-word cuts."""
    if unfixed_tokens <= 0:
        return list(full_tokens)
    if len(full_tokens) <= unfixed_tokens:
        return list(full_tokens[:min_len])

    cut = len(full_tokens) - unfixed_tokens
    if cut <= min_len:
        return list(full_tokens[:min_len])

    # Avoid splitting an ASCII word token sequence (e.g. "Post" + "gre" + "SQL")
    # so the model can still revise the whole English term on the next chunk.
    while cut > min_len:
        next_piece = tokenizer.decode([full_tokens[cut]], skip_special_tokens=True)
        prev_piece = tokenizer.decode([full_tokens[cut - 1]], skip_special_tokens=True)
        if (
            next_piece
            and prev_piece
            and next_piece[0].isascii()
            and next_piece[0].isalnum()
            and prev_piece[-1].isascii()
            and prev_piece[-1].isalnum()
        ):
            cut -= 1
            continue
        break

    candidate = list(full_tokens[:cut])
    # Never leave an incomplete multi-byte UTF-8 sequence at the end of committed prefix.
    while len(candidate) > min_len:
        decoded = tokenizer.decode(candidate, skip_special_tokens=True)
        if "\ufffd" not in decoded:
            break
        candidate.pop()
    return candidate


def _fast_merge_audio_embeds(inner: Any, input_ids: Any, audio_features: Any) -> Any:
    """Merge contiguous <|audio_pad|> embeddings in O(1) MLX concat instead of per-token loop."""
    import mlx.core as mx

    inputs_embeds = inner.model.embed_tokens(input_ids)
    audio_features = audio_features.astype(inputs_embeds.dtype)

    ids_1d = input_ids[0] if input_ids.ndim > 1 else input_ids
    embeds_2d = inputs_embeds[0] if inputs_embeds.ndim > 2 else inputs_embeds
    ids_np = np.array(ids_1d)
    audio_positions = np.where(ids_np == inner.config.audio_token_id)[0]
    if len(audio_positions) == 0 or audio_features.shape[0] == 0:
        return inputs_embeds

    start = int(audio_positions[0])
    count = min(len(audio_positions), int(audio_features.shape[0]))
    end = start + count
    # Fast path when all audio tokens form a single contiguous span (always true for Qwen3-ASR).
    if len(audio_positions) == count and int(audio_positions[-1]) == end - 1:
        parts = []
        if start > 0:
            parts.append(embeds_2d[:start])
        parts.append(audio_features[:count])
        if end < embeds_2d.shape[0]:
            parts.append(embeds_2d[end:])
        merged = mx.concatenate(parts, axis=0)
        return merged[None, :, :] if inputs_embeds.ndim > 2 else merged

    return inner._build_inputs_embeds(input_ids, audio_features)


class Qwen3StreamingSession:
    """Stateful block-cached + prefix-rollback streaming decoder for one utterance window."""

    def __init__(self, model: Any) -> None:
        inner = _unwrap_qwen3_model(model)
        if inner is None:
            raise ValueError("Model does not support native Qwen3-ASR streaming")
        self._inner = inner
        self._block_frames = max(100, int(inner.config.audio_config.n_window_infer))
        self._cached_blocks: dict[int, Any] = {}
        self._committed_token_ids: list[int] = []
        self._step_count = 0

    @property
    def cached_block_count(self) -> int:
        return len(self._cached_blocks)

    @property
    def committed_token_count(self) -> int:
        return len(self._committed_token_ids)

    def reset(self) -> None:
        had_cache = bool(self._cached_blocks)
        self._cached_blocks.clear()
        self._committed_token_ids.clear()
        self._step_count = 0
        if had_cache:
            try:
                import mlx.core as mx
                mx.clear_cache()
            except Exception:
                pass

    def decode(
        self,
        blocks: list[AudioBlock],
        config: AsrConfig,
        *,
        is_final: bool = False,
    ) -> StreamingStepResult:
        if not blocks:
            return StreamingStepResult("", 0, 0, 0, 0, 0.0)

        import mlx.core as mx
        from mlx_lm.generate import generate_step
        from mlx_lm.sample_utils import make_sampler

        start_at = time.perf_counter()
        self._step_count += 1
        inner = self._inner

        audio_wave = np.concatenate([block.samples for block in blocks]).astype(np.float32, copy=False)
        min_samples = int(max(0.0, config.stream_min_chunk_duration) * config.sample_rate)
        if min_samples > 0 and len(audio_wave) < min_samples:
            audio_wave = np.pad(audio_wave, (0, min_samples - len(audio_wave)))

        audio_inputs = inner._feature_extractor(
            audio_wave,
            sampling_rate=config.sample_rate,
            return_attention_mask=True,
            truncation=False,
            padding=True,
            return_tensors="np",
        )
        mel = audio_inputs["input_features"]
        total_frames = int(audio_inputs["attention_mask"].sum())
        if total_frames <= 0:
            return StreamingStepResult("", 0, 0, 0, 0, (time.perf_counter() - start_at) * 1000.0)

        audio_parts = []
        cached_hits = 0
        encoded_count = 0
        num_blocks = (total_frames + self._block_frames - 1) // self._block_frames
        for block_idx in range(num_blocks):
            seg_start = block_idx * self._block_frames
            seg_end = min((block_idx + 1) * self._block_frames, total_frames)
            is_full_block = (seg_end - seg_start) == self._block_frames
            if is_full_block and block_idx in self._cached_blocks:
                audio_parts.append(self._cached_blocks[block_idx])
                cached_hits += 1
                continue

            sub_mel = mx.array(mel[:, :, seg_start:seg_end])
            encoded = inner.get_audio_features(sub_mel, None)
            mx.eval(encoded)
            encoded_count += 1
            if is_full_block and not is_final and total_frames >= seg_end + _STFT_EDGE_MARGIN_FRAMES:
                self._cached_blocks[block_idx] = encoded
            audio_parts.append(encoded)

        audio_features = audio_parts[0] if len(audio_parts) == 1 else mx.concatenate(audio_parts, axis=0)
        num_audio_tokens = int(audio_features.shape[0])

        use_prefix = (
            bool(self._committed_token_ids)
            and (is_final or self._step_count > max(0, config.streaming_unfixed_chunks))
        )
        prefix_tokens = list(self._committed_token_ids) if use_prefix else []

        input_ids = inner._build_prompt(
            num_audio_tokens,
            language=config.language,
            system_prompt=config.system_prompt or None,
        )
        if prefix_tokens:
            prefix_arr = mx.array([prefix_tokens], dtype=input_ids.dtype)
            input_ids = mx.concatenate([input_ids, prefix_arr], axis=1)

        inputs_embeds = _fast_merge_audio_embeds(inner, input_ids, audio_features)
        mx.eval(inputs_embeds)

        audio_seconds = len(audio_wave) / float(config.sample_rate)
        max_new_tokens = min(512, max(64, int(audio_seconds * 14) - len(prefix_tokens) + 64))
        sampler = make_sampler(0.0)

        generated: list[int] = []
        for token, _ in generate_step(
            prompt=input_ids[0],
            input_embeddings=inputs_embeds[0],
            model=inner,
            max_tokens=max_new_tokens,
            sampler=sampler,
        ):
            token_id = int(token)
            if token_id in _EOS_TOKEN_IDS:
                break
            generated.append(token_id)

        full_tokens = prefix_tokens + generated
        if not is_final and self._step_count >= max(1, config.streaming_unfixed_chunks):
            candidate = _trim_safe_prefix_tokens(
                full_tokens,
                max(0, config.streaming_unfixed_tokens),
                inner._tokenizer,
                min_len=len(self._committed_token_ids),
            )
            if len(candidate) > len(self._committed_token_ids):
                self._committed_token_ids = candidate

        text = normalize_text(inner._tokenizer.decode(full_tokens, skip_special_tokens=True))
        elapsed_ms = (time.perf_counter() - start_at) * 1000.0
        return StreamingStepResult(
            text=text,
            prefix_tokens=len(prefix_tokens),
            generated_tokens=len(generated),
            cached_blocks=cached_hits,
            encoded_blocks=encoded_count,
            elapsed_ms=elapsed_ms,
        )
