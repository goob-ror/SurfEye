import numpy as np


def compute_contact_angle_from_circle(cx: float, cy: float, radius: float, baseline_y: float) -> dict:
    """Legacy spherical-cap formula — kept only as a fallback if the
    Young-Laplace fit fails to converge. See young_laplace.py for the
    physically correct (gravity-aware) fit used by default.

        cos(theta) = (baseline_y - cy) / radius
    """
    d = baseline_y - cy
    cos_val = np.clip(d / radius, -1.0, 1.0)
    angle_deg = float(np.degrees(np.arccos(cos_val)))

    discriminant = radius ** 2 - d ** 2
    base = float(np.sqrt(max(discriminant, 0.0)))
    height = float(baseline_y - (cy - radius))

    result = classify_surface(angle_deg, angle_deg)
    result["circle_cx"] = cx
    result["circle_cy"] = cy
    result["circle_radius"] = radius
    result["droplet_height_px"] = height
    result["droplet_width_px"] = base * 2
    return result


def compute_contact_angle(slope_dx_dy: float, side: str = "left") -> float:
    """Legacy polynomial-tangent formula — same fallback role as above."""
    if side == "left":
        slope_dx_dy = -slope_dx_dy
    angle_rad = np.arctan2(1.0, slope_dx_dy)
    return abs(float(np.degrees(angle_rad)))


def classify_surface(left_angle: float, right_angle: float) -> dict:
    avg = (left_angle + right_angle) / 2.0
    if avg >= 150:
        label = "Superhydrophobic"
    elif avg >= 90:
        label = "Hydrophobic"
    elif avg >= 10:
        label = "Hydrophilic"
    else:
        label = "Superhydrophilic"

    return {"left_angle": left_angle, "right_angle": right_angle, "average_angle": avg, "classification": label}
