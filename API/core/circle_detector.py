"""
Circle detection module using Hough Circle Transform.

Detects circular water droplets in images, filtering out smaller circular
artifacts like bokeh highlights and reflections by selecting the largest circle.

Based on OpenCV documentation:
- https://docs.opencv.org/4.x/d4/d70/tutorial_hough_circle.html
- https://learnopencv.com/hough-transform-with-opencv-c-python/
"""

import cv2
import numpy as np
from config import (
    CIRCLE_DP,
    CIRCLE_MIN_DIST,
    CIRCLE_PARAM1,
    CIRCLE_PARAM2,
    CIRCLE_MIN_RADIUS_RATIO,
    CIRCLE_MAX_RADIUS_RATIO,
)


def detect_droplet_circle(
    gray: np.ndarray,
    edges: np.ndarray,
) -> tuple[int, int, int] | None:
    """
    Detect the main water droplet circle using Hough Circle Transform.

    Selects the largest detected circle to prioritize the main droplet over
    smaller circular artifacts (bokeh highlights, reflections).

    Args:
        gray: Grayscale image (8-bit single channel)
        edges: Edge-detected image (for validation, not directly used by HoughCircles)

    Returns:
        Tuple of (center_x, center_y, radius) in pixels, or None if no circle found.

    Algorithm:
        1. Apply median blur to reduce noise (recommended preprocessing)
        2. Run HoughCircles with HOUGH_GRADIENT method
        3. Filter circles within radius bounds (min/max ratios of image height)
        4. Return largest circle by radius
    """
    h, w = gray.shape

    # Calculate radius bounds based on image dimensions
    min_radius = int(h * CIRCLE_MIN_RADIUS_RATIO)
    max_radius = int(h * CIRCLE_MAX_RADIUS_RATIO)

    # Apply median blur before circle detection (reduces noise, preserves edges)
    # Kernel size 5 is recommended in OpenCV documentation
    blurred = cv2.medianBlur(gray, 5)

    # Detect circles using Hough Circle Transform
    # HoughCircles has built-in Canny edge detection, so we pass grayscale
    circles = cv2.HoughCircles(
        blurred,
        cv2.HOUGH_GRADIENT,  # Detection method (only one currently available)
        dp=CIRCLE_DP,  # Inverse accumulator resolution ratio
        minDist=CIRCLE_MIN_DIST,  # Min distance between circle centers
        param1=CIRCLE_PARAM1,  # Canny high threshold for gradient
        param2=CIRCLE_PARAM2,  # Accumulator threshold for center detection
        minRadius=min_radius,  # Minimum circle radius
        maxRadius=max_radius,  # Maximum circle radius
    )

    if circles is None:
        return None

    # Convert to integer coordinates
    circles = np.uint16(np.around(circles))

    # Select the largest circle by radius (main droplet vs bokeh highlights)
    # circles shape: (1, N, 3) where each circle is [x, y, radius]
    largest_circle = max(circles[0, :], key=lambda c: c[2])

    center_x, center_y, radius = largest_circle
    return int(center_x), int(center_y), int(radius)
