import cv2
import numpy as np
from config import CONTOUR_BASELINE_MARGIN


def create_circular_mask(
    shape: tuple[int, int], center_x: int, center_y: int, radius: int
) -> np.ndarray:
    """
    Create a circular mask for region-of-interest contour extraction.

    Args:
        shape: Image shape (height, width)
        center_x: Circle center X coordinate
        center_y: Circle center Y coordinate
        radius: Circle radius in pixels

    Returns:
        Binary mask (255 inside circle, 0 outside)
    """
    mask = np.zeros(shape, dtype=np.uint8)
    cv2.circle(mask, (center_x, center_y), radius, 255, -1)
    return mask


def create_rectangular_mask(
    shape: tuple[int, int], x1: int, y1: int, x2: int, y2: int
) -> np.ndarray:
    """
    Create a rectangular mask for region-of-interest contour extraction.

    Args:
        shape: Image shape (height, width)
        x1, y1: Top-left corner coordinates
        x2, y2: Bottom-right corner coordinates

    Returns:
        Binary mask (255 inside rectangle, 0 outside)
    """
    mask = np.zeros(shape, dtype=np.uint8)
    cv2.rectangle(mask, (x1, y1), (x2, y2), 255, -1)
    return mask


def extract_droplet_contour(
    edges: np.ndarray, baseline_y: int, roi_mask: np.ndarray | None = None
) -> np.ndarray | None:
    """
    Extract the droplet contour from edge-detected image.

    Optionally constrains the search to a region of interest (ROI) defined by
    a mask, which can be circular (from HoughCircles) or rectangular (from
    manual bounding box).

    Args:
        edges: Edge-detected binary image
        baseline_y: Y-coordinate of the baseline (surface)
        roi_mask: Optional binary mask to constrain contour search

    Returns:
        Array of contour points with shape (N, 2) representing (x, y) coordinates,
        or None if no contour found.
    """
    # Start with edges, masking out baseline region
    masked = edges.copy()
    masked[baseline_y - CONTOUR_BASELINE_MARGIN :, :] = 0

    # Apply ROI mask if provided (constrains search to circle or bounding box)
    if roi_mask is not None:
        masked = cv2.bitwise_and(masked, masked, mask=roi_mask)

    # Find contours in the masked region
    contours, _ = cv2.findContours(masked, cv2.RETR_EXTERNAL, cv2.CHAIN_APPROX_NONE)

    if not contours:
        return None

    # Take the largest contour by area
    largest = max(contours, key=cv2.contourArea)
    points = largest[:, 0, :]  # shape (N, 2) — (x, y)

    return points
