"""Semantic + acoustic dual-speed endpointing for live dictation.

Distinguishes genuinely complete sentences (fast close) from mid-thought
pauses or provisional Qwen3-ASR trailing periods after conjunctions/fragments
(full wait up to the user's configured ``vad_end_silence_seconds``).
"""

from __future__ import annotations

import dataclasses
import re

from asr.asr_core import compact_text
from asr.config import AsrConfig

_TERMINAL_STRONG = frozenset("？！?!")
_TERMINAL_DECLARATIVE = frozenset("。.")
_CLAUSE_SPLIT_RE = re.compile(r"[。！？，；：,.!?;:\n]+")
_TRAILING_ASCII_WORD_RE = re.compile(r"([A-Za-z]+)$")

# Short complete utterances that are safe to fast-close even under 6 chars.
_COMPLETE_SHORT_CLOSURES = frozenset({
    "好的", "可以", "对的", "是的", "收到", "明白", "谢谢", "没问题",
    "没关系", "知道了", "继续", "开始", "结束", "停止", "确认", "同意",
    "不错", "挺好的", "挺不错", "没毛病", "搞定", "完成", "可以的",
    "ok", "yes", "no", "thanks", "done", "sure", "nice",
})

# Predicative "...的" endings that indicate a closed Chinese sentence rather
# than an unfinished "modifier + 的 + [noun]" phrase.
_COMPLETE_DE_ENDINGS = (
    "好的", "对的", "是的", "可以的", "没问题的", "不错的", "挺不错的",
    "挺好的", "合理的", "正常的", "一样的", "一样的", "正确的", "准确的",
    "流畅的", "明显的", "有效的", "成功的", "满意的", "认可的", "可以的",
    "没关系的", "知道的", "明白的", "可能的", "必须的", "需要的", "值得的",
)

# Multi-character Chinese transitions, conjunctions, auxiliaries, and
# determiner/numeral phrases that strongly signal an unfinished thought even
# if the ASR model provisionally appended "。".
_DANGLING_ZH_SUFFIXES = (
    "也就是说", "换句话说", "与此同时", "总的来说", "接下来的",
    "首先", "其次", "然后", "但是", "不过", "因为", "所以", "而且",
    "并且", "或者", "如果", "虽然", "既然", "那么", "另外", "同时",
    "比如", "例如", "以及", "还是", "就是", "接下来", "还有", "其实",
    "关于", "针对", "对于", "根据", "通过", "基于", "为了", "除了",
    "只要", "只有", "哪怕", "即使", "无论", "不管", "一旦", "假如",
    "然而", "否则", "于是", "因此", "因而", "从而", "进而", "以便",
    "以免", "随着", "按照", "依据", "正在", "已经", "开始", "准备",
    "打算", "继续", "进行", "试图", "想要", "希望", "需要", "应该",
    "一个", "两个", "三个", "四个", "五个", "六个", "七个", "八个",
    "九个", "十个", "几个", "一些", "这些", "那些", "这个", "那个",
    "这种", "那种", "某个", "每个", "各个", "所有", "以后", "之后",
    "之前", "的时候", "的话",
)

# Single-character Chinese particles/prepositions/conjunctions that rarely end
# a finished declarative sentence (excluding whitelisted "...的" predicates).
_DANGLING_ZH_CHARS = frozenset(
    "的地得在把被将对向从往和与跟同给让叫使比像是有会要想能第"
    "而并或但却又也还再就才都很太更最不没别请"
)

_DANGLING_EN_WORDS = frozenset({
    "and", "or", "but", "so", "because", "if", "then", "that", "which",
    "who", "with", "for", "to", "of", "in", "on", "at", "by", "as",
    "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
    "have", "has", "had", "will", "would", "should", "shall", "can",
    "could", "may", "might", "must", "like", "about", "from", "into",
    "onto", "over", "under", "between", "through", "during", "before",
    "after", "while", "when", "where", "how", "why", "what",
})

_PAIRED_DELIMITERS = (
    ("（", "）"),
    ("(", ")"),
    ("【", "】"),
    ("[", "]"),
    ("《", "》"),
    ("“", "”"),
    ("‘", "’"),
)


@dataclasses.dataclass(frozen=True)
class EndpointDecision:
    threshold_seconds: float
    mode: str
    reason: str


def _has_unclosed_delimiters(text: str) -> bool:
    for left, right in _PAIRED_DELIMITERS:
        if text.count(left) > text.count(right):
            return True
    if text.count('"') % 2 == 1:
        return True
    return False


def _is_dangling_ending(body: str, last_clause: str) -> str | None:
    ascii_match = _TRAILING_ASCII_WORD_RE.search(body)
    if ascii_match:
        if ascii_match.group(1).lower() in _DANGLING_EN_WORDS:
            return "dangling_en"
        return None

    for suffix in _DANGLING_ZH_SUFFIXES:
        if last_clause.endswith(suffix):
            return "dangling_zh_phrase"

    if last_clause and last_clause[-1] == "的":
        if any(last_clause.endswith(ok) for ok in _COMPLETE_DE_ENDINGS):
            return None
        return "dangling_de"

    if last_clause and last_clause[-1] in _DANGLING_ZH_CHARS:
        return "dangling_zh_char"

    return None


def compute_end_silence_threshold(
    base_end_silence: float,
    last_partial_text: str,
    *,
    partial_fresh: bool,
    config: AsrConfig,
) -> EndpointDecision:
    """Compute effective silence duration before finalizing an active utterance."""
    base = max(0.05, float(base_end_silence))
    if not config.semantic_endpointing_enabled:
        return EndpointDecision(base, "disabled", "disabled")

    min_fast = max(0.05, float(config.semantic_fast_min_silence_seconds))
    if base <= min_fast + 1e-9:
        return EndpointDecision(base, "full_wait", "base_already_fast")

    text = last_partial_text.strip()
    if not partial_fresh or not text:
        return EndpointDecision(base, "full_wait", "stale_or_empty_partial")

    if _has_unclosed_delimiters(text):
        return EndpointDecision(base, "full_wait", "unclosed_delimiter")

    # Ellipsis ("..." / "……") signals trailing off or thinking, never fast-close.
    if text.endswith("..") or text.endswith("…"):
        return EndpointDecision(base, "full_wait", "ellipsis")

    tail_char = text[-1]
    is_strong = tail_char in _TERMINAL_STRONG
    is_declarative = tail_char in _TERMINAL_DECLARATIVE
    if not (is_strong or is_declarative):
        return EndpointDecision(base, "full_wait", "no_terminal_punctuation")

    body = text.rstrip("。！？.!? \t")
    # Avoid treating decimal numbers / version strings ("3.", "v1.") as sentence ends.
    if is_declarative and body and body[-1].isdigit():
        return EndpointDecision(base, "full_wait", "trailing_digit")

    compact_body = compact_text(body)
    if not compact_body:
        return EndpointDecision(base, "full_wait", "empty_body")

    clauses = [compact_text(part) for part in _CLAUSE_SPLIT_RE.split(body)]
    clauses = [clause for clause in clauses if clause]
    last_clause = clauses[-1] if clauses else compact_body

    dangling = _is_dangling_ending(body, last_clause)
    if dangling is not None:
        return EndpointDecision(base, "full_wait", dangling)

    is_known_short = compact_body.lower() in _COMPLETE_SHORT_CLOSURES
    min_total = 4 if is_strong else 6
    min_clause = 3 if is_strong else 4
    if not is_known_short and (len(compact_body) < min_total or len(last_clause) < min_clause):
        return EndpointDecision(base, "full_wait", "short_fragment")

    if is_strong:
        ratio = max(0.2, min(1.0, float(config.semantic_fast_question_ratio)))
        fast = min(base, max(min_fast, base * ratio))
        return EndpointDecision(fast, "fast_question", "terminal_question_or_exclam")

    ratio = max(0.2, min(1.0, float(config.semantic_fast_silence_ratio)))
    fast = min(base, max(min_fast, base * ratio))
    return EndpointDecision(fast, "fast_close", "closed_declarative")
