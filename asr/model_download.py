"""Local-cache-first HuggingFace model resolver with byte-level download progress."""

from __future__ import annotations

import logging
from pathlib import Path
import threading
import time
from typing import Any, Callable

logger = logging.getLogger(__name__)

# Callback signature: (stage, progress_0_to_1_or_none, downloaded_bytes, total_bytes)
ProgressCallback = Callable[[str, float | None, int, int], None]


def make_progress_tqdm_class(
    on_progress: ProgressCallback,
    *,
    min_interval_seconds: float = 0.2,
    base_cls: type | None = None,
) -> type:
    """Create a tqdm-compatible class that reports aggregated byte download progress."""
    if base_cls is None:
        try:
            from huggingface_hub.utils import tqdm as hf_tqdm

            base_cls = hf_tqdm
        except Exception:
            class _MinimalTqdm:
                def __init__(self, *args: Any, **kwargs: Any) -> None:
                    self.total = kwargs.get("total") or 0
                    self.n = kwargs.get("initial") or 0

                def update(self, n: int | float | None = 1) -> None:
                    if n:
                        self.n += n

                def refresh(self) -> None:
                    pass

                def set_description(self, _desc: str = "", refresh: bool = True) -> None:
                    if refresh:
                        self.refresh()

                def close(self) -> None:
                    pass

                def __enter__(self) -> "_MinimalTqdm":
                    return self

                def __exit__(self, *_exc: Any) -> None:
                    self.close()

            base_cls = _MinimalTqdm

    lock = threading.Lock()
    state = {"last_emit": 0.0, "last_pct": -1}

    def _emit(downloaded: int, total: int, *, force: bool = False) -> None:
        if total <= 0:
            return
        clamped_dl = max(0, min(downloaded, total))
        ratio = max(0.0, min(1.0, float(clamped_dl) / float(total)))
        pct = int(ratio * 100)
        now = time.monotonic()
        with lock:
            if not force and pct < 100:
                if pct == state["last_pct"]:
                    return
                if (now - state["last_emit"]) < min_interval_seconds and abs(pct - state["last_pct"]) < 2:
                    return
            state["last_emit"] = now
            state["last_pct"] = pct
        try:
            on_progress("downloading", ratio, clamped_dl, total)
        except Exception:
            logger.debug("download progress callback failed", exc_info=True)

    class _ByteProgressTqdm(base_cls):  # type: ignore[misc, valid-type]
        def __init__(self, *args: Any, **kwargs: Any) -> None:
            self._is_bytes_bar = kwargs.get("unit") == "B"
            super().__init__(*args, **kwargs)

        def update(self, n: int | float | None = 1) -> Any:
            result = super().update(n)
            if self._is_bytes_bar:
                total = int(getattr(self, "total", 0) or 0)
                current = int(getattr(self, "n", 0) or 0)
                _emit(current, total)
            return result

        def refresh(self, *args: Any, **kwargs: Any) -> Any:
            result = super().refresh(*args, **kwargs)
            if self._is_bytes_bar:
                total = int(getattr(self, "total", 0) or 0)
                current = int(getattr(self, "n", 0) or 0)
                _emit(current, total)
            return result

        def set_description(self, desc: str | None = None, refresh: bool = True) -> Any:
            result = super().set_description(desc, refresh=refresh)
            if self._is_bytes_bar and desc and "complete" in desc.lower():
                total = int(getattr(self, "total", 0) or 0)
                if total > 0:
                    _emit(total, total, force=True)
            return result

    return _ByteProgressTqdm


def resolve_or_download_model(
    model_id: str,
    *,
    on_progress: ProgressCallback | None = None,
    snapshot_download_fn: Callable[..., str] | None = None,
) -> str:
    """Return a local model directory, downloading with byte progress only when not cached."""
    raw = model_id.strip()
    if not raw:
        return model_id
    if Path(raw).exists():
        if on_progress is not None:
            on_progress("loading", None, 0, 0)
        return raw

    if snapshot_download_fn is None:
        try:
            from huggingface_hub import snapshot_download as snapshot_download_fn
        except ImportError:
            if on_progress is not None:
                on_progress("loading", None, 0, 0)
            return raw

    try:
        cached = snapshot_download_fn(raw, local_files_only=True)
        if cached and Path(cached).exists():
            if on_progress is not None:
                on_progress("loading", None, 0, 0)
            return cached
    except Exception:
        pass

    if on_progress is not None:
        on_progress("downloading", 0.0, 0, 0)
        tqdm_cls = make_progress_tqdm_class(on_progress)
        downloaded = snapshot_download_fn(raw, tqdm_class=tqdm_cls)
        on_progress("loading", None, 0, 0)
        return downloaded

    return snapshot_download_fn(raw)
