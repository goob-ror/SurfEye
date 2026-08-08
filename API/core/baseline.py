import cv2
import numpy as np
from config import BASELINE_ANGLE_TOLERANCE, BASELINE_Y_OFFSET, BASELINE_FALLBACK_THRESHOLD


def detect_baseline(edges: np.ndarray) -> int | None:
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
