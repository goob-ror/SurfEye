import numpy as np

from .config import Settings

try:
    import cv2
    _HAS_CV2 = True
except ImportError:  # pragma: no cover - see README_ANDROID.md
    _HAS_CV2 = False


def preprocess(image_path: str, settings: Settings = None) -> tuple[np.ndarray, np.ndarray]:
    """Load image, convert to grayscale, blur, and run Canny edge detection.

    Requires OpenCV. On Android via Chaquopy, OpenCV is frequently NOT
    available (see README_ANDROID.md) — in that setup, do this step in
    Kotlin using Android's native OpenCV binding instead, and call
    `preprocess_from_edges()` below with the resulting edge map.
    """
    if not _HAS_CV2:
        raise RuntimeError(
            "OpenCV is not available in this environment. On Android, "
            "run edge detection in Kotlin/native OpenCV and pass the "
            "resulting edge map into the Python side directly (see "
            "surfeye.analyze.analyze_droplet(edges=..., img_shape=...))."
        )

    settings = settings or Settings()

    img = cv2.imread(image_path)
    if img is None:
        raise FileNotFoundError(f"Image not found: {image_path}")

    k = settings.blur_kernel_size
    if k % 2 == 0:
        k += 1  # Canny/Gaussian kernel must be odd

    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    blurred = cv2.GaussianBlur(gray, (k, k), 0)
    edges = cv2.Canny(
        blurred,
        threshold1=settings.canny_threshold_low,
        threshold2=settings.canny_threshold_high,
    )

    return img, edges


def edges_from_array(bgr_or_gray: np.ndarray, settings: Settings = None) -> np.ndarray:
    """Same as preprocess(), but starting from an in-memory array instead
    of a file path. Useful when Kotlin hands Python a decoded Bitmap
    (e.g. as a numpy array via a shared buffer) rather than a file path.
    """
    if not _HAS_CV2:
        raise RuntimeError("OpenCV is not available in this environment.")

    settings = settings or Settings()
    arr = bgr_or_gray
    if arr.ndim == 3:
        gray = cv2.cvtColor(arr, cv2.COLOR_BGR2GRAY)
    else:
        gray = arr

    k = settings.blur_kernel_size
    if k % 2 == 0:
        k += 1

    blurred = cv2.GaussianBlur(gray, (k, k), 0)
    return cv2.Canny(blurred, settings.canny_threshold_low, settings.canny_threshold_high)
