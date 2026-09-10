import cv2
import numpy as np
from config import BASELINE_ANGLE_TOLERANCE


def detect_substrate_angle(edges: np.ndarray) -> float:
    """
    Detect the tilt angle of the substrate/baseline using Hough Line Transform.
    
    Args:
        edges: Binary edge-detected image
        
    Returns:
        Tilt angle in degrees (positive = clockwise rotation needed)
    """
    h, w = edges.shape
    
    # Focus on bottom half of image where substrate typically is
    roi = edges[h // 2:, :]
    
    # Detect lines using Hough Transform with multiple attempts
    attempts = [
        dict(threshold=80, minLineLength=w // 3, maxLineGap=20),
        dict(threshold=50, minLineLength=w // 5, maxLineGap=40),
        dict(threshold=30, minLineLength=w // 8, maxLineGap=60),
    ]
    
    all_angles = []
    for params in attempts:
        lines = cv2.HoughLinesP(roi, rho=1, theta=np.pi / 180, **params)
        if lines is None:
            continue
            
        for line in lines:
            seg = line[0] if line.ndim == 2 else line
            x1, y1, x2, y2 = seg
            
            # Calculate angle from horizontal
            angle = np.degrees(np.arctan2(y2 - y1, x2 - x1))
            
            # Filter for nearly horizontal lines (within tolerance)
            if abs(angle) < BASELINE_ANGLE_TOLERANCE:
                all_angles.append(angle)
    
    if len(all_angles) == 0:
        return 0.0  # No tilt detected
    
    # Use median angle to be robust against outliers
    median_angle = float(np.median(all_angles))
    return median_angle


def rotate_image(image: np.ndarray, angle: float) -> tuple[np.ndarray, np.ndarray]:
    """
    Rotate image to correct for substrate tilt.
    
    Args:
        image: Input image (color or grayscale)
        angle: Rotation angle in degrees (positive = clockwise)
        
    Returns:
        Tuple of (rotated_image, rotation_matrix)
    """
    if abs(angle) < 0.1:  # Skip rotation for negligible angles
        h, w = image.shape[:2]
        identity = np.array([[1, 0, 0], [0, 1, 0]], dtype=np.float32)
        return image.copy(), identity
    
    h, w = image.shape[:2]
    center = (w / 2, h / 2)
    
    # Get rotation matrix (negative angle because we want to counter-rotate)
    rotation_matrix = cv2.getRotationMatrix2D(center, -angle, 1.0)
    
    # Calculate new bounding dimensions to avoid cropping
    cos = np.abs(rotation_matrix[0, 0])
    sin = np.abs(rotation_matrix[0, 1])
    
    new_w = int(h * sin + w * cos)
    new_h = int(h * cos + w * sin)
    
    # Adjust rotation matrix to account for translation
    rotation_matrix[0, 2] += (new_w / 2) - center[0]
    rotation_matrix[1, 2] += (new_h / 2) - center[1]
    
    # Perform rotation with white background for better edge detection
    rotated = cv2.warpAffine(
        image, 
        rotation_matrix, 
        (new_w, new_h),
        flags=cv2.INTER_LINEAR,
        borderMode=cv2.BORDER_CONSTANT,
        borderValue=(255, 255, 255) if len(image.shape) == 2 else (255, 255, 255)
    )
    
    return rotated, rotation_matrix


def correct_tilt(image: np.ndarray, edges: np.ndarray) -> tuple[np.ndarray, np.ndarray, float]:
    """
    Detect and correct substrate tilt in the image.
    
    Args:
        image: Original input image (BGR or grayscale)
        edges: Edge-detected binary image
        
    Returns:
        Tuple of (corrected_image, corrected_edges, tilt_angle)
    """
    # Detect tilt angle from edges
    tilt_angle = detect_substrate_angle(edges)
    
    # Rotate both original image and edges
    corrected_image, _ = rotate_image(image, tilt_angle)
    corrected_edges, _ = rotate_image(edges, tilt_angle)
    
    return corrected_image, corrected_edges, tilt_angle
