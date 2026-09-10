import cv2
import numpy as np
from config import (
    BLUR_KERNEL_SIZE, CANNY_THRESHOLD_LOW, CANNY_THRESHOLD_HIGH,
    EDGE_CLEAN_ENABLED, EDGE_CLEAN_BINARY_THRESHOLD, EDGE_CLEAN_CONNECTIVITY,
    EDGE_CLEAN_MIN_AREA, EDGE_CLEAN_MIN_AREA_ELONGATED, EDGE_CLEAN_MIN_ASPECT,
)


def adjust_brightness_contrast(gray: np.ndarray, brightness: int = 0, contrast: float = 1.0) -> np.ndarray:
    """
    Adjust brightness and contrast of a grayscale image.
    
    Args:
        gray: Input grayscale image
        brightness: Brightness adjustment in range [-100, 100] (default 0)
        contrast: Contrast multiplier in range [0.5, 3.0] (default 1.0)
        
    Returns:
        Adjusted grayscale image
    """
    if brightness == 0 and contrast == 1.0:
        return gray
    
    img = gray.astype(np.float32)
    img = img * contrast + brightness
    return np.clip(img, 0, 255).astype(np.uint8)


def detect_roi_bounds(image: np.ndarray, padding: int = 50) -> tuple[int, int, int, int]:
    """
    Detect the region of interest (ROI) containing the droplet by finding
    the bounding box of significant content, excluding far background.
    
    Args:
        image: Grayscale image
        padding: Pixels to add around detected content (default 50)
        
    Returns:
        Tuple of (x1, y1, x2, y2) representing ROI bounds
    """
    h, w = image.shape[:2]
    
    # Use adaptive thresholding to find content regions
    # This helps separate droplet from uniform background
    blurred = cv2.GaussianBlur(image, (9, 9), 0)
    thresh = cv2.adaptiveThreshold(
        blurred, 255, cv2.ADAPTIVE_THRESH_GAUSSIAN_C,
        cv2.THRESH_BINARY_INV, 21, 10
    )
    
    # Find contours of content regions
    contours, _ = cv2.findContours(thresh, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_SIMPLE)
    
    if not contours:
        # No content detected, return full image
        return 0, 0, w, h
    
    # Get bounding box of all significant contours combined
    all_points = []
    for cnt in contours:
        area = cv2.contourArea(cnt)
        # Only include contours larger than 1% of image area
        if area > (h * w * 0.01):
            all_points.extend(cnt[:, 0, :].tolist())
    
    if not all_points:
        # No significant content, return full image
        return 0, 0, w, h
    
    all_points = np.array(all_points)
    x_min = max(0, int(all_points[:, 0].min()) - padding)
    y_min = max(0, int(all_points[:, 1].min()) - padding)
    x_max = min(w, int(all_points[:, 0].max()) + padding)
    y_max = min(h, int(all_points[:, 1].max()) + padding)
    
    return x_min, y_min, x_max, y_max


def crop_to_roi(image: np.ndarray, roi_bounds: tuple[int, int, int, int]) -> np.ndarray:
    """
    Crop image to region of interest.
    
    Args:
        image: Input image (color or grayscale)
        roi_bounds: Tuple of (x1, y1, x2, y2)
        
    Returns:
        Cropped image
    """
    x1, y1, x2, y2 = roi_bounds
    return image[y1:y2, x1:x2].copy()


def clean_edges(edges: np.ndarray) -> np.ndarray:
    """
    Remove isolated noise blobs from a Canny edge map using connected-component
    analysis. Only components that are large enough OR thin/elongated enough
    (droplet-boundary-like) are retained.

    Thresholds are controlled by the EDGE_CLEAN_* constants in config.py:
        EDGE_CLEAN_BINARY_THRESHOLD  – binarisation cutoff (default 30)
        EDGE_CLEAN_CONNECTIVITY      – 4 or 8 (default 8)
        EDGE_CLEAN_MIN_AREA          – blobs ≥ this area are always kept (default 300 px²)
        EDGE_CLEAN_MIN_AREA_ELONGATED – secondary min area for elongated blobs (default 80 px²)
        EDGE_CLEAN_MIN_ASPECT        – aspect-ratio threshold for elongated blobs (default 3.0)
        EDGE_CLEAN_ENABLED           – set False to bypass cleaning entirely
    """
    if not EDGE_CLEAN_ENABLED:
        return edges

    _, binary = cv2.threshold(
        edges, EDGE_CLEAN_BINARY_THRESHOLD, 255, cv2.THRESH_BINARY
    )

    num_labels, labels, stats, _ = cv2.connectedComponentsWithStats(
        binary, connectivity=EDGE_CLEAN_CONNECTIVITY
    )

    clean = np.zeros_like(binary)
    for i in range(1, num_labels):           # skip label 0 (background)
        area = stats[i, cv2.CC_STAT_AREA]
        w    = stats[i, cv2.CC_STAT_WIDTH]
        h    = stats[i, cv2.CC_STAT_HEIGHT]
        aspect = max(w, h) / max(min(w, h), 1)

        if area >= EDGE_CLEAN_MIN_AREA:
            clean[labels == i] = 255
        elif area >= EDGE_CLEAN_MIN_AREA_ELONGATED and aspect >= EDGE_CLEAN_MIN_ASPECT:
            clean[labels == i] = 255

    return clean


def preprocess(
    image_path: str, 
    apply_roi: bool = True,
    brightness: int = 0,
    contrast: float = 1.0,
    canny_threshold_low: int | None = None,
    canny_threshold_high: int | None = None,
) -> tuple[np.ndarray, np.ndarray, tuple[int, int, int, int] | None]:
    """
    Preprocess image: load, convert to grayscale, optionally crop ROI, detect edges, and clean.
    
    Args:
        image_path: Path to input image
        apply_roi: Whether to detect and crop to ROI (default True)
        brightness: Brightness adjustment in range [-100, 100] (default 0)
        contrast: Contrast multiplier in range [0.5, 3.0] (default 1.0)
        canny_threshold_low: Override for Canny low threshold (default from config)
        canny_threshold_high: Override for Canny high threshold (default from config)
        
    Returns:
        Tuple of (original_image, edges, roi_bounds)
        roi_bounds is None if apply_roi is False
    """
    img = cv2.imread(image_path)
    if img is None:
        raise FileNotFoundError(f"Image not found: {image_path}")

    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    
    # Apply brightness and contrast adjustments
    gray = adjust_brightness_contrast(gray, brightness, contrast)
    
    # Detect ROI bounds on full image (before cropping)
    roi_bounds = None
    if apply_roi:
        roi_bounds = detect_roi_bounds(gray)
        # Note: We return roi_bounds but don't crop yet - 
        # cropping will be done after tilt correction in pipeline
    
    # Use provided thresholds or fall back to config defaults
    threshold_low = canny_threshold_low if canny_threshold_low is not None else CANNY_THRESHOLD_LOW
    threshold_high = canny_threshold_high if canny_threshold_high is not None else CANNY_THRESHOLD_HIGH
    
    blurred = cv2.GaussianBlur(gray, (BLUR_KERNEL_SIZE, BLUR_KERNEL_SIZE), 0)
    edges = cv2.Canny(blurred, threshold1=threshold_low, threshold2=threshold_high)
    edges = clean_edges(edges)

    return img, edges, roi_bounds
