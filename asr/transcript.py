"""Text ownership for a logical utterance spanning several audio windows.

Audio-window boundaries are computational checkpoints, not sentence endings.
The caller decodes both sides of the actual audio cut independently. They must
cover the whole-window hypothesis before text/audio ownership can move. Merely
finding a suffix would accept truncated overlap decodes and duplicate words.
"""

from __future__ import annotations

import unicodedata


def _content_positions(text: str) -> tuple[str, list[int]]:
    """Ignore punctuation/space for anchoring, retaining original offsets."""
    positions = [
        index
        for index, character in enumerate(text)
        if not character.isspace() and not unicodedata.category(character).startswith("P")
    ]
    return "".join(text[index] for index in positions), positions


class RollingTranscript:
    """An immutable confirmed prefix followed by a revisable visible draft.

    ``update`` and ``finish`` receive a hypothesis for the current audio window,
    which includes retained overlap after a successful ``checkpoint``.  The
    next window begins with that overlap, rather than the preceding full audio.
    Rejected candidates leave all text unchanged; ``last_update_accepted`` and
    ``last_error`` make this explicit to the engine.

    Text becomes confirmed only when its audio leaves the compute window at
    an anchored checkpoint. Repeated partial agreement alone cannot prove a
    boundary: a later decode can still change an earlier word or punctuation.
    All text belonging to retained audio therefore remains revisable.
    """

    def __init__(self) -> None:
        self.reset()

    @property
    def text(self) -> str:
        return self._text

    @property
    def committed(self) -> str:
        return self._committed

    @property
    def draft(self) -> str:
        return self._text[len(self._committed):]

    def reset(self) -> None:
        self._text = ""
        self._committed = ""
        self._base = ""
        self._sealed_boundary = False
        self._checkpoint_signature: tuple[str, str, str] | None = None
        self._finished = False
        self.last_update_accepted = True
        self.last_error: str | None = None

    def _reject(self, reason: str) -> None:
        self.last_update_accepted = False
        self.last_error = reason

    def _compose(self, hypothesis: str) -> str:
        # A resource fallback starts independent audio without overlap. Model
        # normalization strips leading spaces, so preserve Latin word separation
        # at this explicit join; ordinary overlapping windows retain their cut.
        separator = ""
        if self._sealed_boundary and self._base and hypothesis:
            left, right = self._base[-1], hypothesis[0]
            if left.isascii() and left.isalnum() and right.isascii() and right.isalnum():
                separator = " "
        return self._base + separator + hypothesis

    def update(self, hypothesis: str) -> str:
        """Replace text owned by the current retained audio window."""
        if self._finished:
            self._reject("finished")
            return self.text
        if not _content_positions(hypothesis)[0]:
            self._reject("empty_hypothesis")
            return self.text
        self._text = self._compose(hypothesis)
        self._checkpoint_signature = None
        self.last_update_accepted = True
        self.last_error = None
        return self.text

    def checkpoint(self, hypothesis: str, overlap_hypothesis: str, prefix_hypothesis: str) -> bool:
        """Roll only when decodes of both audio sides cover the whole window.

        Failure is atomic: neither the visible text nor its base/confirmation
        boundary changes.  Retrying the same successful checkpoint before any
        new update is harmless.  Identical words in subsequent windows are
        otherwise preserved, rather than globally deduplicated.
        """
        if self._finished:
            self._reject("finished")
            return False
        signature = (hypothesis, overlap_hypothesis, prefix_hypothesis)
        if self._checkpoint_signature == signature:
            self.last_update_accepted = True
            self.last_error = None
            return True
        overlap, _ = _content_positions(overlap_hypothesis)
        if not overlap:
            self._reject("empty_overlap")
            return False
        candidate = self._compose(hypothesis)
        content, positions = _content_positions(hypothesis)
        if not content.endswith(overlap):
            self._reject("overlap_not_suffix")
            return False
        prefix, _ = _content_positions(prefix_hypothesis)
        if prefix + overlap != content:
            self._reject("audio_cut_coverage_mismatch")
            return False

        overlap_start = len(candidate) - len(hypothesis) + positions[len(prefix)]

        self._text = candidate
        self._base = candidate[:overlap_start]
        self._committed = self._base
        self._sealed_boundary = False
        self._checkpoint_signature = signature
        self.last_update_accepted = True
        self.last_error = None
        return True

    def seal_window(self, hypothesis: str) -> str:
        """Bound audio memory when safe overlap alignment remains impossible.

        Seal visible text without declaring the logical utterance final.  The
        next hypothesis must contain entirely new audio, with no overlap. This
        fallback preserves confirmed text, but offers no punctuation repair
        across this boundary and is exposed for evaluation/telemetry.
        """
        if self._finished:
            self._reject("finished")
            return self.text
        if _content_positions(hypothesis)[0]:
            self._text = self._compose(hypothesis)
        self._base = self._text
        self._committed = self._text
        self._sealed_boundary = True
        self._checkpoint_signature = None
        self.last_update_accepted = True
        self.last_error = "alignment_fallback"
        return self.text

    def finish(self, hypothesis: str) -> str:
        """Confirm a natural/explicit end; repeated finalization is idempotent."""
        if self._finished:
            return self.text
        if _content_positions(hypothesis)[0]:
            self._text = self._compose(hypothesis)
        self._committed = self._text
        self._finished = True
        self._checkpoint_signature = None
        self.last_update_accepted = True
        self.last_error = None
        return self.text
