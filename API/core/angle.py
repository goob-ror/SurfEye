import numpy as np


def compute_contact_angle_from_circle(cx: float, cy: float, radius: float, baseline_y: float) -> dict:
    """
    Compute the sessile-droplet contact angle from a fitted circle.

    Geometry (image coords, y increases downward):
      - The circle center is at (cx, cy), above the baseline (cy < baseline_y).
      - The circle intersects the baseline at the two contact points.
      - At each contact point the radius is perpendicular to the droplet surface,
        so the contact angle θ satisfies:
            cos(θ) = (baseline_y - cy) / radius
        This is the standard sessile-drop formula.
      - θ < 90°  → hydrophilic   (center above baseline, circle dips into surface)
      - θ > 90°  → hydrophobic   (center below top of droplet but circle still intersects baseline)
    """
    d = baseline_y - cy          # vertical distance from center to baseline (>0 when center is above)
    cos_val = np.clip(d / radius, -1.0, 1.0)
    angle_deg = float(np.degrees(np.arccos(cos_val)))

    # Chord half-length at baseline
    discriminant = radius ** 2 - d ** 2
    base = float(np.sqrt(max(discriminant, 0.0)))

    # Droplet height = distance from baseline down to top of circle
    # top of circle in image coords = cy - radius  (smallest y value)
    height = float(baseline_y - (cy - radius))

    result = classify_surface(angle_deg, angle_deg)
    result["circle_cx"] = cx
    result["circle_cy"] = cy
    result["circle_radius"] = radius
    result["droplet_height_px"] = height
    result["droplet_width_px"] = base * 2
    return result


def compute_contact_angle(slope_dx_dy: float, side: str = "left") -> float:
    """
    Convert tangent slope dx/dy at the contact point to a contact angle in degrees,
    measured through the liquid from the baseline.

    The polynomial fits x = f(y), so slope = dx/dy.
    Upward tangent vector in math coords (y up): (slope_dx_dy, 1).

    RIGHT side: arctan2(1, slope_dx_dy) directly gives the correct obtuse angle
                for a hydrophobic droplet (was giving 157° correctly).
    LEFT side:  mirror of right — negate the slope so the same formula applies.
    """
    if side == "left":
        slope_dx_dy = -slope_dx_dy
    angle_rad = np.arctan2(1.0, slope_dx_dy)
    return abs(float(np.degrees(angle_rad)))


def classify_surface(left_angle: float, right_angle: float) -> dict:
    """
    Average left and right contact angles and classify the surface wettability.
    """
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
