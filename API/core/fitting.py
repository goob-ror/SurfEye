import cv2
import numpy as np
from scipy import optimize
from config import FITTING_POLYNOMIAL_DEGREE, FITTING_CONTACT_REGION_PX


def fit_ellipse_to_droplet(points: np.ndarray, baseline_y: int) -> dict | None:
    """
    Fit an ellipse to the droplet contour above the baseline.
    This is the preferred method for contact angle measurement as it better
    represents the actual droplet shape compared to polynomial fitting.
    
    Args:
        points: Array of contour points with shape (N, 2) as (x, y)
        baseline_y: Y-coordinate of the baseline (surface)
        
    Returns:
        Dictionary containing ellipse parameters and contact points, or None if fitting fails
        {
            'center': (cx, cy),
            'axes': (major_axis, minor_axis),
            'angle': rotation_angle_deg,
            'left_contact': (lx, ly),
            'right_contact': (rx, ry),
            'contact_points_valid': bool
        }
    """
    if points is None or len(points) < 5:
        return None
    
    # Filter points above baseline (with small margin to exclude surface noise)
    margin = 5
    mask = points[:, 1] < (baseline_y - margin)
    filtered_points = points[mask]
    
    if len(filtered_points) < 5:
        return None
    
    try:
        # OpenCV's fitEllipse requires at least 5 points
        # Returns ((cx, cy), (major, minor), angle)
        ellipse = cv2.fitEllipse(filtered_points)
        
        (cx, cy), (d1, d2), angle_deg = ellipse
        
        # Ensure major axis is the larger one
        major_axis = max(d1, d2) / 2.0  # Convert diameter to radius
        minor_axis = min(d1, d2) / 2.0
        
        # Adjust angle if axes were swapped
        if d2 > d1:
            angle_deg = (angle_deg + 90) % 180
        
        # Find contact points where ellipse intersects baseline
        # We need to find x values where the ellipse equation equals baseline_y
        contact_points = find_ellipse_baseline_intersection(
            cx, cy, major_axis, minor_axis, angle_deg, baseline_y
        )
        
        result = {
            'center': (float(cx), float(cy)),
            'axes': (float(major_axis), float(minor_axis)),
            'angle': float(angle_deg),
            'contact_points_valid': contact_points is not None
        }
        
        if contact_points is not None:
            result['left_contact'] = contact_points[0]
            result['right_contact'] = contact_points[1]
        else:
            # Fallback: use leftmost and rightmost points on baseline
            x_coords = filtered_points[:, 0]
            result['left_contact'] = (float(x_coords.min()), float(baseline_y))
            result['right_contact'] = (float(x_coords.max()), float(baseline_y))
        
        return result
        
    except cv2.error:
        return None


def find_ellipse_baseline_intersection(
    cx: float, cy: float, a: float, b: float, angle_deg: float, baseline_y: float
) -> tuple[tuple[float, float], tuple[float, float]] | None:
    """
    Find the intersection points of an ellipse with a horizontal baseline.
    
    Args:
        cx, cy: Ellipse center coordinates
        a: Semi-major axis
        b: Semi-minor axis
        angle_deg: Rotation angle in degrees
        baseline_y: Y-coordinate of baseline
        
    Returns:
        Tuple of ((left_x, baseline_y), (right_x, baseline_y)) or None if no intersection
    """
    # Convert angle to radians
    theta = np.radians(angle_deg)
    cos_t = np.cos(theta)
    sin_t = np.sin(theta)
    
    # Translate so ellipse center is at origin
    dy = baseline_y - cy
    
    # Rotated ellipse equation: ((x*cos + y*sin)/a)^2 + ((-x*sin + y*cos)/b)^2 = 1
    # We want to solve for x when y = dy
    # This becomes a quadratic equation in x
    
    A = (cos_t / a) ** 2 + (sin_t / b) ** 2
    B = 2 * dy * (cos_t * sin_t / (a ** 2) - cos_t * sin_t / (b ** 2))
    C = (dy * sin_t / a) ** 2 + (dy * cos_t / b) ** 2 - 1
    
    discriminant = B ** 2 - 4 * A * C
    
    if discriminant < 0:
        return None  # No intersection
    
    sqrt_disc = np.sqrt(discriminant)
    x1 = (-B - sqrt_disc) / (2 * A) + cx
    x2 = (-B + sqrt_disc) / (2 * A) + cx
    
    # Ensure left < right
    left_x = min(x1, x2)
    right_x = max(x1, x2)
    
    return ((float(left_x), float(baseline_y)), (float(right_x), float(baseline_y)))


def compute_ellipse_contact_angle(
    cx: float, cy: float, a: float, b: float, angle_deg: float,
    contact_x: float, baseline_y: float
) -> float:
    """
    Compute contact angle at a point where the ellipse touches the baseline.
    
    Uses the ellipse tangent at the contact point to compute the angle
    with respect to the horizontal baseline.
    
    Args:
        cx, cy: Ellipse center
        a: Semi-major axis
        b: Semi-minor axis  
        angle_deg: Ellipse rotation angle in degrees
        contact_x: X-coordinate of contact point
        baseline_y: Y-coordinate of baseline
        
    Returns:
        Contact angle in degrees (0-180°)
    """
    theta = np.radians(angle_deg)
    cos_t = np.cos(theta)
    sin_t = np.sin(theta)
    
    # Point on ellipse (in world coords)
    px = contact_x - cx
    py = baseline_y - cy
    
    # Rotate to ellipse frame
    px_rot = px * cos_t + py * sin_t
    py_rot = -px * sin_t + py * cos_t
    
    # Tangent in ellipse frame: dx/dy = -(b²*x) / (a²*y)
    # But we want dy/dx for image coordinates
    if abs(py_rot) < 1e-6:
        # Point is at extremum, tangent is horizontal
        return 90.0
    
    # dy/dx in ellipse frame
    dy_dx_ellipse = -(a ** 2 * py_rot) / (b ** 2 * px_rot) if abs(px_rot) > 1e-6 else np.inf
    
    # Rotate tangent back to world frame
    # Tangent vector in ellipse frame: (1, dy_dx_ellipse)
    tx_ellipse = 1.0
    ty_ellipse = dy_dx_ellipse
    
    # Rotate back
    tx_world = tx_ellipse * cos_t - ty_ellipse * sin_t
    ty_world = tx_ellipse * sin_t + ty_ellipse * cos_t
    
    # In image coords (y down), tangent angle from horizontal
    angle_rad = np.arctan2(-ty_world, tx_world)  # Negative because y-axis is flipped
    angle = np.degrees(angle_rad)
    
    # Normalize to 0-180° range
    if angle < 0:
        angle += 180
    
    return float(angle)


def fit_circle(points: np.ndarray, baseline_y: int) -> tuple[float, float, float] | None:
    """
    Fit a circle to the droplet contour points above the baseline.
    Returns (cx, cy, radius) or None if fitting fails.

    Constraints enforced:
      - circle center must be above the baseline (cy < baseline_y)
      - radius must be positive and large enough to reach the baseline
        i.e.  radius >= (baseline_y - cy)  so the circle actually touches the surface
    """
    # Strip points at or below the baseline, plus a small margin to avoid surface noise
    margin = 8
    mask = points[:, 1] < (baseline_y - margin)
    pts = points[mask]
    if len(pts) < 10:
        return None

    x = pts[:, 0].astype(float)
    y = pts[:, 1].astype(float)

    # Initial guess: centroid + RMS radius
    cx0, cy0 = x.mean(), y.mean()
    r0 = float(np.sqrt(((x - cx0) ** 2 + (y - cy0) ** 2).mean()))

    def circle_residuals(params):
        cx, cy, r = params
        return np.sqrt((x - cx) ** 2 + (y - cy) ** 2) - r

    img_w = float(x.max() - x.min())

    # Bounds: cx free within image width, cy must be above baseline, r > 0
    lower = [x.min() - img_w, -np.inf,          1.0]
    upper = [x.max() + img_w,  baseline_y - 1.0, np.inf]

    try:
        result = optimize.least_squares(
            circle_residuals, [cx0, cy0, r0],
            bounds=(lower, upper),
            method="trf",
        )
        cx, cy, r = result.x
        r = abs(r)

        # Sanity check: circle must intersect the baseline
        if r < (baseline_y - cy) * 0.5:
            return None

        return float(cx), float(cy), r
    except Exception:
        return None


def fit_droplet_profile(points: np.ndarray, baseline_y: int, degree: int = FITTING_POLYNOMIAL_DEGREE) -> tuple:
    """
    Fit a polynomial to the left and right edges of the droplet profile.
    Only uses points near the baseline (within FITTING_CONTACT_REGION_PX) for the tangent.
    Returns (left_fit, right_fit, left_contact_x, right_contact_x).
    """
    x = points[:, 0].astype(float)
    y = points[:, 1].astype(float)

    x_mid = (x.max() + x.min()) / 2
    left_mask = x <= x_mid
    right_mask = x > x_mid

    left_x, left_y = x[left_mask], y[left_mask]
    right_x, right_y = x[right_mask], y[right_mask]

    # Fit polynomial: x as function of y (better for near-vertical edges)
    left_fit = np.polyfit(left_y, left_x, degree) if len(left_y) > degree else None
    right_fit = np.polyfit(right_y, right_x, degree) if len(right_y) > degree else None

    left_contact_x = float(np.polyval(left_fit, baseline_y)) if left_fit is not None else None
    right_contact_x = float(np.polyval(right_fit, baseline_y)) if right_fit is not None else None

    return left_fit, right_fit, left_contact_x, right_contact_x


def tangent_slope_at(fit_coeffs: np.ndarray, y_val: float) -> float:
    """
    Compute dx/dy at a given y using the derivative of the polynomial fit.
    Returns the slope dx/dy.
    """
    derivative = np.polyder(fit_coeffs)
    return float(np.polyval(derivative, y_val))
