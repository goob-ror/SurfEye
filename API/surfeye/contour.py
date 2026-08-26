import numpy as np

from .config import Settings

try:
    import cv2
    _HAS_CV2 = True
except ImportError:  # pragma: no cover
    _HAS_CV2 = False


def extract_droplet_contour(
    edges: np.ndarray, baseline_y: int, settings: Settings = None
) -> np.ndarray | None:
    if not _HAS_CV2:
        raise RuntimeError(
            "Contour extraction needs OpenCV's findContours, which isn't "
            "available in this environment. Run this step in Kotlin/native "
            "OpenCV and pass the resulting (N,2) point array straight into "
            "surfeye.young_laplace.fit_young_laplace()."
        )

    settings = settings or Settings()

    masked = edges.copy()
    margin = settings.contour_baseline_margin
    masked[baseline_y - margin:, :] = 0

    contours, _ = cv2.findContours(masked, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)
    if not contours:
        return None

    largest = max(contours, key=cv2.contourArea)
    return largest[:, 0, :]  # (N, 2) — (x, y)
