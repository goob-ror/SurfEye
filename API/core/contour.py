import cv2
import numpy as np
from config import CONTOUR_BASELINE_MARGIN


def extract_droplet_contour(edges: np.ndarray, baseline_y: int) -> np.ndarray | None:
    masked = edges.copy()
    masked[baseline_y - CONTOUR_BASELINE_MARGIN:, :] = 0

    contours, _ = cv2.findContours(masked, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)

    if not contours:
        return None

    # Take the largest contour
    largest = max(contours, key=cv2.contourArea)
    points = largest[:, 0, :]  # shape (N, 2) — (x, y)

    return points
