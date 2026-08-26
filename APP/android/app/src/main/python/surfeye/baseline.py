import numpy as np

from .config import Settings

try:
    import cv2
    _HAS_CV2 = True
except ImportError:  # pragma: no cover
    _HAS_CV2 = False


def detect_baseline(
    edges: np.ndarray,
    settings: Settings = None,
    baseline_y: int | None = None,
) -> int | None:
    """
    Locate the y-pixel of the solid-surface line.

    baseline_y:
        - None (default) -> AUTO mode: detect via Hough lines, falling
          back to edge-density row. This is the normal path.
        - int -> MANUAL mode: use this value as-is (no offset applied,
          since a manually-placed line is already exactly where the
          user/UI put it). This is what a Flutter "drag the baseline"
          slider/handle should call with, passing the pixel row the
          user selected.

    Returns the baseline y-coordinate, or None if AUTO detection fails
    and no manual value was given.
    """
    settings = settings or Settings()

    if baseline_y is not None:
        return int(baseline_y)

    return _auto_detect_baseline(edges, settings)


def _auto_detect_baseline(edges: np.ndarray, settings: Settings) -> int | None:
    if not _HAS_CV2:
        raise RuntimeError(
            "Auto baseline detection needs OpenCV's Hough transform, which "
            "isn't available in this environment. Either pass baseline_y "
            "explicitly, or run Hough line detection in Kotlin/native "
            "OpenCV and pass the resulting y value in as baseline_y."
        )

    h, w = edges.shape

    attempts = [
        dict(threshold=80, minLineLength=w // 3, maxLineGap=20),
        dict(threshold=50, minLineLength=w // 5, maxLineGap=40),
        dict(threshold=30, minLineLength=w // 8, maxLineGap=60),
    ]

    for params in attempts:
        lines = cv2.HoughLinesP(edges, rho=1, theta=np.pi / 180, **params)
        if lines is None:
            continue
        horizontal = []
        for line in lines:
            x1, y1, x2, y2 = line[0]
            angle = abs(np.degrees(np.arctan2(y2 - y1, x2 - x1)))
            if angle < settings.baseline_angle_tolerance:
                horizontal.append((y1 + y2) // 2)
        if horizontal:
            return int(np.median(horizontal)) + settings.baseline_y_offset

    # Fallback: lowest row with a high density of edge pixels.
    row_sums = np.sum(edges, axis=1)
    threshold = row_sums.max() * settings.baseline_fallback_threshold
    dense_rows = np.where(row_sums > threshold)[0]
    if len(dense_rows) > 0:
        return int(dense_rows[-1]) + settings.baseline_y_offset

    return None
