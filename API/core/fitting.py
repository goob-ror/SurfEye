import numpy as np
from scipy import optimize
from config import FITTING_POLYNOMIAL_DEGREE, FITTING_CONTACT_REGION_PX


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
