"""Optional end-of-utterance local oral polisher (rules + lazy MLX LLM + hard guardrails).

Runs strictly on the MLX worker thread right before emitting ``on_final``.
When disabled (default), consumes 0 MB RAM and adds 0 ms latency.
When enabled:
1. Deterministic rule pass strips standalone fillers and immediate stutters.
2. Lazy-loaded local MLX Instruct LLM resolves self-repairs and fragmented
   punctuation on utterances >= ``oral_polish_min_chars``.
3. Strict mathematical guardrails reject truncation, expansion/answering,
   technical-term/number corruption, or meta-commentary, falling back safely
   to the rule-cleaned transcript.
"""

from __future__ import annotations

from collections import Counter
import dataclasses
import logging
import re
import time
from typing import Any, Callable

from asr.asr_core import compact_text, normalize_text
from asr.config import AsrConfig

logger = logging.getLogger(__name__)

DEFAULT_POLISH_SYSTEM_PROMPT = (
    "你是中文语音听写顺稿器，负责清理口语听写中的杂音，保留原意和原本的表达习惯：\n"
    "1. 删掉口语填充词（嗯、啊、呃、那个）、重复口吃，以及说话人改口重说时前面说错或被放弃的半句（保留后面的说法）。\n"
    "2. 合并句中被错误断开的句号/问号，修正标点；疑问句保持疑问句。\n"
    "3. 如果原句已经通顺，请原样输出，不要换词或改写。\n"
    "4. 必须原样保留所有英文术语、数字和路径；不要回答问题，只输出顺稿后的文本。"
)

DEFAULT_POLISH_FEW_SHOT: tuple[dict[str, str], ...] = (
    {"role": "user", "content": "这个想法，这个方案，能把延迟降下来吗？"},
    {"role": "assistant", "content": "这个方案能把延迟降下来吗？"},
    {"role": "user", "content": "你可以。先预置一部分。你对这个的，基于你对这个项目的了解，你可以预置一部分。"},
    {"role": "assistant", "content": "你可以基于你对这个项目的了解预置一部分。"},
    {"role": "user", "content": "你们当时是怎么能？查出来的，我怎么能先？首先是看日志，然后再定位。关键是怎么复现的？"},
    {"role": "assistant", "content": "你们当时是怎么查出来的？首先是看日志，然后再定位。关键是怎么复现的？"},
    {"role": "user", "content": "我们今天把 Docker 和 Nginx 的配置核对一遍，端口 8080 别冲突。"},
    {"role": "assistant", "content": "我们今天把 Docker 和 Nginx 的配置核对一遍，端口 8080 别冲突。"},
)

_PROMPT_SPLIT_SENTINEL = "__MACOSASR_POLISH_INPUT__"

_LEADING_FILLER_RE = re.compile(r"^(?:嗯+|啊+|呃+|额+|诶+|哦+)[，、。！？,\.\s]+")
_MID_FILLER_RE = re.compile(r"([，。！？；：、])\s*(?:嗯+|啊+|呃+|额+|诶+|哦+)\s*([，、。！？])")
_PUNCT_STUTTER_RE = re.compile(r"([\u4e00-\u9fffA-Za-z0-9]{2,6})(?:[，、\s]+\1)+")
_MULTI_PUNCT_RE = re.compile(r"([，、；：])\1+")
_COMMA_BEFORE_PERIOD_RE = re.compile(r"[，、]+([。！？])")
_THINK_TAG_RE = re.compile(r"<think>.*?</think>", re.DOTALL)
_WRAPPER_PREFIX_RE = re.compile(r"^(?:顺稿结果|顺稿后|顺稿|修改后|润色后|输出|正文)\s*[：:]\s*")
_ASCII_TOKEN_RE = re.compile(r"[A-Za-z][A-Za-z0-9_.\-+#]*|\d+(?:\.\d+)?")
_META_PREFIXES = ("好的，", "好的。", "当然，", "当然可以", "作为AI", "作为一个", "抱歉", "以下是", "修改如下")


@dataclasses.dataclass(frozen=True)
class PolishResult:
    text: str
    mode: str  # "disabled" | "rules_only" | "llm" | "fallback_rules"
    reason: str
    elapsed_ms: float


def clean_oral_rules(text: str) -> str:
    """Fast, zero-hallucination cleanup for standalone fillers and punctuated stutters."""
    cleaned = normalize_text(text)
    if not cleaned:
        return ""

    # Strip leading standalone filler ("啊，默认关闭。" -> "默认关闭。").
    while True:
        updated = _LEADING_FILLER_RE.sub("", cleaned)
        if updated == cleaned or not updated:
            break
        cleaned = updated

    # Collapse mid-sentence standalone fillers ("热词的话，嗯，你可以" -> "热词的话，你可以").
    while True:
        updated = _MID_FILLER_RE.sub(lambda m: m.group(1), cleaned)
        if updated == cleaned:
            break
        cleaned = updated

    # Deduplicate punctuated immediate stutters ("增删、增删" -> "增删").
    cleaned = _PUNCT_STUTTER_RE.sub(r"\1", cleaned)
    cleaned = _MULTI_PUNCT_RE.sub(r"\1", cleaned)
    cleaned = _COMMA_BEFORE_PERIOD_RE.sub(r"\1", cleaned)
    return normalize_text(cleaned)


def _strip_llm_wrappers(original: str, raw_output: str) -> str:
    cleaned = _THINK_TAG_RE.sub("", raw_output).strip()
    cleaned = _WRAPPER_PREFIX_RE.sub("", cleaned).strip()
    # Strip outer quotes only if the original text was not quoted.
    if len(cleaned) >= 2:
        for left, right in (('"', '"'), ("“", "”"), ("'", "'")):
            if cleaned.startswith(left) and cleaned.endswith(right):
                if not (original.startswith(left) and original.endswith(right)):
                    cleaned = cleaned[1:-1].strip()
    return normalize_text(cleaned)


def _extract_protected_tokens(text: str) -> set[str]:
    """Return lowercased technical identifiers & numbers that must survive polishing."""
    tokens: set[str] = set()
    for match in _ASCII_TOKEN_RE.findall(text):
        if match[0].isdigit() or len(match) >= 2 or match.isupper():
            tokens.add(match.lower())
    return tokens


def validate_polished_output(original: str, candidate: str) -> tuple[bool, str]:
    """Hard invariant check preventing truncation, expansion, or term corruption."""
    orig_compact = compact_text(original)
    cand_compact = compact_text(candidate)
    if not cand_compact:
        return False, "empty"

    orig_len = len(orig_compact)
    cand_len = len(cand_compact)
    if cand_len < max(4, int(orig_len * 0.55)):
        return False, "truncated"
    if cand_len > int(orig_len * 1.12) + 4:
        return False, "expanded"

    for meta in _META_PREFIXES:
        if candidate.startswith(meta) and not original.startswith(meta):
            return False, "meta_prefix"

    cand_lower = candidate.lower()
    cand_compact_lower = cand_compact.lower()
    for token in _extract_protected_tokens(original):
        token_compact = compact_text(token).lower()
        if token not in cand_lower and (not token_compact or token_compact not in cand_compact_lower):
            return False, "lost_protected_token"

    orig_counts = Counter(orig_compact.lower())
    cand_counts = Counter(cand_compact.lower())
    shared = sum(min(count, orig_counts[ch]) for ch, count in cand_counts.items())
    if shared / float(cand_len) < 0.65:
        return False, "low_overlap"

    return True, "ok"


class OralPolisher:
    """Worker-thread local MLX LLM oral polisher with lazy load and explicit unload."""

    def __init__(
        self,
        *,
        loader: Callable[[str], tuple[Any, Any]] | None = None,
        generator: Callable[..., str] | None = None,
    ) -> None:
        self._loader = loader
        self._generator = generator
        self._model_id: str | None = None
        self._model: Any = None
        self._tokenizer: Any = None
        self._load_failed_for: str | None = None
        self._prefix_cache_states: list[tuple[Any, Any]] | None = None
        self._prompt_suffix: str | None = None

    @property
    def is_loaded(self) -> bool:
        return self._model is not None and self._tokenizer is not None

    def unload(self) -> None:
        had_model = self._model is not None
        self._model = None
        self._tokenizer = None
        self._model_id = None
        self._load_failed_for = None
        self._prefix_cache_states = None
        self._prompt_suffix = None
        if had_model:
            try:
                import mlx.core as mx
                mx.clear_cache()
            except Exception:
                pass
            logger.info("oral_polisher unloaded")

    def preload_if_cached(self, model_id: str) -> bool:
        """Warm up local cached polisher on the worker thread without triggering network downloads."""
        model_id = model_id.strip()
        if not model_id:
            return False
        if self._model is not None and self._model_id == model_id:
            return True
        if self._loader is None and self._resolve_local_cache(model_id) is None:
            return False
        return self._ensure_loaded(model_id)

    def _ensure_loaded(self, model_id: str) -> bool:
        if self._model is not None and self._model_id == model_id:
            return True
        if self._load_failed_for == model_id:
            return False
        if self._model is not None and self._model_id != model_id:
            self.unload()

        start = time.perf_counter()
        try:
            if self._loader is not None:
                model, tokenizer = self._loader(model_id)
            else:
                from mlx_lm import load as load_lm
                resolved = self._resolve_local_cache(model_id) or model_id
                model, tokenizer = load_lm(resolved)
        except Exception:
            self._load_failed_for = model_id
            logger.exception("oral_polisher load failed model=%s", model_id)
            return False

        self._model = model
        self._tokenizer = tokenizer
        self._model_id = model_id
        self._load_failed_for = None
        self._prefix_cache_states = None
        self._prompt_suffix = None
        if self._loader is None and self._generator is None:
            self._prepare_prefix_cache_and_warmup()
        logger.info(
            "oral_polisher loaded model=%s prefix_cached=%s load_ms=%.1f",
            model_id,
            self._prefix_cache_states is not None,
            (time.perf_counter() - start) * 1000.0,
        )
        return True

    def _prepare_prefix_cache_and_warmup(self) -> None:
        """Pre-evaluate system + few-shot KV states once and compile Metal kernels."""
        try:
            import mlx.core as mx
            from mlx_lm import generate as lm_generate
            from mlx_lm.models.cache import make_prompt_cache
            from mlx_lm.sample_utils import make_sampler

            template = self._build_prompt(_PROMPT_SPLIT_SENTINEL)
            if _PROMPT_SPLIT_SENTINEL not in template:
                return
            prefix_part, suffix_part = template.split(_PROMPT_SPLIT_SENTINEL, 1)
            prefix_tokens = self._tokenizer.encode(prefix_part)
            if not prefix_tokens:
                return

            base_cache = make_prompt_cache(self._model)
            self._model(mx.array([prefix_tokens]), cache=base_cache)
            frozen_states = [
                (mx.array(k), mx.array(v))
                for k, v in (layer_cache.state for layer_cache in base_cache)
            ]
            mx.eval([arr for pair in frozen_states for arr in pair])
            self._prefix_cache_states = frozen_states
            self._prompt_suffix = suffix_part

            # 1-token warmup eliminates Metal shader compile stall on the first spoken sentence.
            warm_tokens = self._tokenizer.encode("测试" + suffix_part, add_special_tokens=False)
            lm_generate(
                self._model,
                self._tokenizer,
                prompt=warm_tokens,
                max_tokens=1,
                sampler=make_sampler(temp=0.0),
                prompt_cache=self._clone_prefix_cache(),
                verbose=False,
            )
        except Exception:
            self._prefix_cache_states = None
            self._prompt_suffix = None
            logger.debug("oral_polisher prefix cache setup skipped; using full prompt", exc_info=True)

    def _clone_prefix_cache(self) -> Any:
        assert self._prefix_cache_states is not None
        import mlx.core as mx
        from mlx_lm.models.cache import make_prompt_cache

        cloned = make_prompt_cache(self._model)
        for dst, (k, v) in zip(cloned, self._prefix_cache_states):
            dst.state = (mx.array(k), mx.array(v))
        return cloned

    @staticmethod
    def _resolve_local_cache(model_id: str) -> str | None:
        try:
            from huggingface_hub import snapshot_download
            return snapshot_download(model_id, local_files_only=True)
        except Exception:
            return None

    def _build_prompt(self, text: str) -> str:
        messages = [
            {"role": "system", "content": DEFAULT_POLISH_SYSTEM_PROMPT},
            *DEFAULT_POLISH_FEW_SHOT,
            {"role": "user", "content": text},
        ]
        try:
            return self._tokenizer.apply_chat_template(
                messages,
                tokenize=False,
                add_generation_prompt=True,
                enable_thinking=False,
            )
        except TypeError:
            return self._tokenizer.apply_chat_template(
                messages,
                tokenize=False,
                add_generation_prompt=True,
            )

    def _generate(self, text: str, max_tokens: int) -> str:
        if self._generator is not None:
            prompt = self._build_prompt(text)
            return self._generator(self._model, self._tokenizer, prompt=prompt, max_tokens=max_tokens)
        from mlx_lm import generate as lm_generate
        from mlx_lm.sample_utils import make_sampler

        if self._prefix_cache_states is not None and self._prompt_suffix is not None:
            user_tokens = self._tokenizer.encode(text + self._prompt_suffix, add_special_tokens=False)
            return lm_generate(
                self._model,
                self._tokenizer,
                prompt=user_tokens,
                max_tokens=max_tokens,
                sampler=make_sampler(temp=0.0),
                prompt_cache=self._clone_prefix_cache(),
                verbose=False,
            )

        prompt = self._build_prompt(text)
        return lm_generate(
            self._model,
            self._tokenizer,
            prompt=prompt,
            max_tokens=max_tokens,
            sampler=make_sampler(temp=0.0),
            verbose=False,
        )

    def polish(self, text: str, config: AsrConfig) -> PolishResult:
        if not config.oral_polish_enabled or not text.strip():
            return PolishResult(text=text, mode="disabled", reason="disabled", elapsed_ms=0.0)

        start = time.perf_counter()
        rule_cleaned = clean_oral_rules(text)
        if not rule_cleaned:
            return PolishResult(
                text=text,
                mode="fallback_rules",
                reason="empty_after_rules",
                elapsed_ms=(time.perf_counter() - start) * 1000.0,
            )

        if len(compact_text(rule_cleaned)) < max(1, config.oral_polish_min_chars):
            return PolishResult(
                text=rule_cleaned,
                mode="rules_only",
                reason="short_utterance",
                elapsed_ms=(time.perf_counter() - start) * 1000.0,
            )

        model_id = config.oral_polish_model.strip()
        if not model_id or not self._ensure_loaded(model_id):
            return PolishResult(
                text=rule_cleaned,
                mode="fallback_rules",
                reason="model_unavailable",
                elapsed_ms=(time.perf_counter() - start) * 1000.0,
            )

        try:
            max_tokens = min(384, max(48, int(len(rule_cleaned) * 1.4)))
            raw_out = self._generate(rule_cleaned, max_tokens=max_tokens)
        except Exception:
            logger.exception("oral_polisher generation failed; falling back to rules")
            return PolishResult(
                text=rule_cleaned,
                mode="fallback_rules",
                reason="generate_error",
                elapsed_ms=(time.perf_counter() - start) * 1000.0,
            )

        candidate = _strip_llm_wrappers(rule_cleaned, raw_out)
        ok, reason = validate_polished_output(rule_cleaned, candidate)
        elapsed_ms = (time.perf_counter() - start) * 1000.0
        if not ok:
            logger.warning("oral_polisher rejected reason=%s elapsed_ms=%.1f", reason, elapsed_ms)
            return PolishResult(
                text=rule_cleaned,
                mode="fallback_rules",
                reason=f"rejected:{reason}",
                elapsed_ms=elapsed_ms,
            )

        return PolishResult(text=candidate, mode="llm", reason="ok", elapsed_ms=elapsed_ms)
