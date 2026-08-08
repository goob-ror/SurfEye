import cv2
import numpy as np
from config import BLUR_KERNEL_SIZE, CANNY_THRESHOLD_LOW, CANNY_THRESHOLD_HIGH


def preprocess(image_path: str) -> tuple[np.ndarray, np.ndarray]:
    img = cv2.imread(image_path)
    if img is None:
        raise FileNotFoundError(f"Image not found: {image_path}")

    gray = cv2.cvtColor(img, cv2.COLOR_BGR2GRAY)
    blurred = cv2.GaussianBlur(gray, (BLUR_KERNEL_SIZE, BLUR_KERNEL_SIZE), 0)
    edges = cv2.Canny(blurred, threshold1=CANNY_THRESHOLD_LOW, threshold2=CANNY_THRESHOLD_HIGH)

    return img, edges
