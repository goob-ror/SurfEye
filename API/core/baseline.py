import cv2
import numpy as np
from config import BASELINE_ANGLE_TOLERANCE, BASELINE_Y_OFFSET, BASELINE_FALLBACK_THRESHOLD


def detect_baseline_percentile(contour_points: np.ndarray, percentile: float = 10.0) -> int | None:
    """
    Detect baseline using geometric percentile method on contour points.
    This is more robust than pixel minimum as it's less sensitive to outliers.
    
    The 10th percentile of y-coordinates gives a stable baseline estimate that
    isn't affected by a few noisy points below the true contact line.
    
    Args:
        contour_points: Array of contour points with shape (N, 2) as (x, y)
        percentile: Percentile to use for baseline detection (default 10.0)
        
    Returns:
        Y-coordinate of the baseline, or None if insufficient points
    """
    if contour_points is None or len(contour_points) < 10:
        return None
    
    y_coords = contour_points[:, 1]
    
    # In image coordinates, y increases downward, so we want a high percentile
    # to get the bottom of the droplet (near the substrate)
    # Using 90th percentile (100 - 10) to get the lower boundary
    baseline_y = np.percentile(y_coords, 100 - percentile)
    
    return int(baseline_y) + BASELINE_Y_OFFSET


def detect_baseline(edges: np.ndarray) -> int | None:
    """
    Detect baseline using Hough Line Transform (legacy method).
    
    This method attempts to find horizontal lines in the edge map.
    For best results, use detect_baseline_percentile() with contour points instead.
    
    Args:
        edges: Binary edge-detected image
        
    Returns:
        Y-coordinate of detected baseline, or None if detection fails
    """
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
            # HoughLinesP returns shape (N,1,4) or (N,4) depending on OpenCV version
            seg = line[0] if line.ndim == 2 else line
            x1, y1, x2, y2 = seg
            angle = abs(np.degrees(np.arctan2(y2 - y1, x2 - x1)))
            if angle < BASELINE_ANGLE_TOLERANCE:
                horizontal.append((y1 + y2) // 2)
        if horizontal:
            return int(np.median(horizontal)) + BASELINE_Y_OFFSET

    # Fallback: find the lowest row with a high density of edge pixels
    row_sums = np.sum(edges, axis=1)
    threshold = row_sums.max() * BASELINE_FALLBACK_THRESHOLD
    dense_rows = np.where(row_sums > threshold)[0]
    if len(dense_rows) > 0:
        return int(dense_rows[-1]) + BASELINE_Y_OFFSET

    return None
