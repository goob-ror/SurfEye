import cv2
import numpy as np
import matplotlib.pyplot as plt

from config import ANGLE_LINE_LENGTH, PIXELS_PER_MM
from core.preprocessor import preprocess
from core.baseline import detect_baseline
from core.contour import extract_droplet_contour
from core.fitting import fit_droplet_profile, tangent_slope_at, fit_circle
from core.angle import compute_contact_angle, classify_surface, compute_contact_angle_from_circle


def run(image_path: str, visualize: bool = True, baseline_y_override: int | None = None) -> dict:
    # 1. Preprocess
    img, edges = preprocess(image_path)

    # 2. Detect baseline (auto, then optionally override with user value)
    detected_baseline_y = detect_baseline(edges)
    if detected_baseline_y is None:
        raise RuntimeError("Could not detect baseline. Check image contrast or lighting.")

    baseline_y = baseline_y_override if baseline_y_override is not None else detected_baseline_y

    # 3. Extract droplet contour
    points = extract_droplet_contour(edges, baseline_y)
    if points is None:
        raise RuntimeError("Could not extract droplet contour.")

    # 4. Fit polynomial profiles to left/right edges — primary method
    left_fit, right_fit, left_cx, right_cx = fit_droplet_profile(points, baseline_y)
    if left_fit is None or right_fit is None:
        raise RuntimeError("Polynomial fitting failed — not enough contour points.")

    # 5. Compute tangent slopes at contact points
    left_slope = tangent_slope_at(left_fit, baseline_y)
    right_slope = tangent_slope_at(right_fit, baseline_y)

    # 6. Compute contact angles
    left_angle = compute_contact_angle(left_slope, side="left")
    right_angle = compute_contact_angle(right_slope, side="right")

    result = classify_surface(left_angle, right_angle)
    result["method"] = "polynomial"
    result["detected_baseline_y"] = detected_baseline_y
    result["baseline_y"] = baseline_y

    # 7. Save images
    import os
    base, ext = os.path.splitext(image_path)
    edge_image_path = base + "_edges.png"
    cv2.imwrite(edge_image_path, edges)
    result["edge_image_path"] = edge_image_path

    # 8. Generate and save annotated visualization (always, for API clients)
    annotated_image_path = base + "_annotated.png"
    _visualize_to_file(img, edges, baseline_y, points, left_cx, right_cx, left_slope, right_slope, result, annotated_image_path)
    result["annotated_image_path"] = annotated_image_path

    if visualize:
        _visualize(img, edges, baseline_y, points, left_cx, right_cx, left_slope, right_slope, result)

    return result


def _visualize_circle(img, edges, baseline_y, points, cx, cy, radius, result):
    """Visualize the circle-fit result."""
    vis = img.copy()
    h, w = vis.shape[:2]

    # Baseline
    cv2.line(vis, (0, baseline_y), (w, baseline_y), (0, 255, 0), 2)

    # Contour points
    for x, y in points:
        cv2.circle(vis, (int(x), int(y)), 1, (255, 0, 0), -1)

    # Fitted circle
    cv2.circle(vis, (int(cx), int(cy)), int(radius), (0, 200, 255), 2)

    # Contact points (where circle meets baseline)
    discriminant = radius ** 2 - (baseline_y - cy) ** 2
    if discriminant >= 0:
        half_chord = float(np.sqrt(discriminant))
        lx, rx = int(cx - half_chord), int(cx + half_chord)
        cv2.circle(vis, (lx, baseline_y), 6, (0, 0, 255), -1)
        cv2.circle(vis, (rx, baseline_y), 6, (0, 0, 255), -1)

    # Width and height lines
    droplet_width_px = int(result.get("droplet_width_px", 0))
    droplet_height_px = int(result.get("droplet_height_px", 0))

    def to_mm(px):
        return round(px / PIXELS_PER_MM, 3) if PIXELS_PER_MM else None

    width_mm = to_mm(droplet_width_px)
    height_mm = to_mm(droplet_height_px)

    result["droplet_width_mm"] = width_mm
    result["droplet_height_mm"] = height_mm

    fig, axes = plt.subplots(1, 2, figsize=(12, 5))
    axes[0].imshow(cv2.cvtColor(vis, cv2.COLOR_BGR2RGB))
    axes[0].set_title("Detected Droplet (Circle Fit)")
    axes[0].axis("off")

    axes[1].imshow(edges, cmap="gray")
    axes[1].set_title("Edge Map")
    axes[1].axis("off")

    fig.suptitle(
        f"Contact Angle: {result['average_angle']:.1f}°  →  {result['classification']}\n"
        f"Circle radius: {radius:.1f}px   "
        f"Width: {droplet_width_px}px   Height: {droplet_height_px}px   [circle fit]",
        fontsize=13,
    )
    plt.tight_layout()
    plt.show()


def _draw_angle_line(vis, contact_x, baseline_y, slope_dx_dy, length=ANGLE_LINE_LENGTH):
    """Draw the tangent line at a contact point upward into the droplet."""
    if contact_x is None:
        return
    cx, cy = int(contact_x), baseline_y
    # tangent direction upward: (dx, dy) where dy = -length (up in image), dx = slope * (-length)
    dy = -length
    dx = int(slope_dx_dy * dy)
    cv2.line(vis, (cx, cy), (cx + dx, cy + dy), (0, 0, 255), 2)


def _draw_dotted_arc(vis, cx, cy, radius, start_angle_deg, end_angle_deg, color=(128, 0, 128), dot_gap=6):
    """Draw a dotted arc between two angles (degrees, math convention: 0=right, CCW positive)."""
    a_start = np.radians(min(start_angle_deg, end_angle_deg))
    a_end = np.radians(max(start_angle_deg, end_angle_deg))
    arc_len = radius * (a_end - a_start)
    num_dots = max(int(arc_len / dot_gap), 2)
    for i in range(num_dots):
        t = a_start + (a_end - a_start) * i / (num_dots - 1)
        px = int(cx + radius * np.cos(t))
        py = int(cy - radius * np.sin(t))  # image y is flipped
        cv2.circle(vis, (px, py), 2, color, -1)


def _draw_angle_arc(vis, contact_x, baseline_y, slope_dx_dy, angle_deg, side="left", arc_radius=40):
    """
    Draw a purple dotted arc showing the contact angle at a contact point.
    Arc sweeps from the baseline (toward droplet center) to the tangent, through the liquid.
    """
    if contact_x is None:
        return
    cx, cy = int(contact_x), baseline_y

    # Mirror left side so both use the same right-side convention
    s = -slope_dx_dy if side == "left" else slope_dx_dy
    tangent_angle = float(np.degrees(np.arctan2(1.0, s)))  # 0°–180°

    if side == "left":
        arc_start = 0.0
        arc_end = tangent_angle
    else:
        arc_start = 180.0 - tangent_angle
        arc_end = 180.0

    _draw_dotted_arc(vis, cx, cy, arc_radius, arc_start, arc_end)

    mid_angle = np.radians((arc_start + arc_end) / 2)
    lx = int(cx + (arc_radius + 18) * np.cos(mid_angle))
    ly = int(cy - (arc_radius + 18) * np.sin(mid_angle))
    cv2.putText(vis, f"{angle_deg:.1f}", (lx - 15, ly),
                cv2.FONT_HERSHEY_SIMPLEX, 0.55, (128, 0, 128), 2)


def _visualize_to_file(img, edges, baseline_y, points, left_cx, right_cx, left_slope, right_slope, result, output_path: str):
    """Generate annotated visualization and save to file without displaying."""
    vis = img.copy()
    h, w = vis.shape[:2]

    # Draw baseline
    cv2.line(vis, (0, baseline_y), (w, baseline_y), (0, 255, 0), 2)

    # Draw contour points
    for x, y in points:
        cv2.circle(vis, (int(x), int(y)), 1, (255, 0, 0), -1)

    # Draw contact points
    if left_cx:
        cv2.circle(vis, (int(left_cx), baseline_y), 6, (0, 0, 255), -1)
    if right_cx:
        cv2.circle(vis, (int(right_cx), baseline_y), 6, (0, 0, 255), -1)

    # Draw angle tangent lines in red
    _draw_angle_line(vis, left_cx, baseline_y, left_slope)
    _draw_angle_line(vis, right_cx, baseline_y, right_slope)

    # Draw dotted arc showing the contact angle at each contact point
    _draw_angle_arc(vis, left_cx, baseline_y, left_slope, result["left_angle"], side="left")
    _draw_angle_arc(vis, right_cx, baseline_y, right_slope, result["right_angle"], side="right")

    # Draw droplet width (horizontal) and height (vertical) lines in red
    x_coords = points[:, 0]
    y_coords = points[:, 1]
    x_min, x_max = int(x_coords.min()), int(x_coords.max())
    y_min = int(y_coords.min())  # topmost point of droplet
    y_max = baseline_y           # bottom is the baseline

    droplet_width_px = x_max - x_min
    droplet_height_px = y_max - y_min

    # Convert to mm if calibrated
    def to_mm(px):
        return round(px / PIXELS_PER_MM, 3) if PIXELS_PER_MM else None

    width_mm = to_mm(droplet_width_px)
    height_mm = to_mm(droplet_height_px)

    w_label = f"W: {droplet_width_px}px" + (f" ({width_mm}mm)" if width_mm else "")
    h_label = f"H: {droplet_height_px}px" + (f" ({height_mm}mm)" if height_mm else "")

    # Horizontal width line at the vertical midpoint of the droplet
    y_mid = (y_min + y_max) // 2
    cv2.line(vis, (x_min, y_mid), (x_max, y_mid), (0, 0, 255), 2)
    cv2.putText(vis, w_label, (x_min, y_mid - 8),
                cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 0, 255), 2)

    # Vertical height line at the horizontal midpoint of the droplet
    x_mid_drop = (x_min + x_max) // 2
    cv2.line(vis, (x_mid_drop, y_min), (x_mid_drop, y_max), (0, 0, 255), 2)
    cv2.putText(vis, h_label, (x_mid_drop + 6, y_min + droplet_height_px // 2),
                cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 0, 255), 2)

    result["droplet_width_px"] = droplet_width_px
    result["droplet_height_px"] = droplet_height_px
    result["droplet_width_mm"] = width_mm
    result["droplet_height_mm"] = height_mm

    # Save annotated image to file
    cv2.imwrite(output_path, vis)


def _visualize(img, edges, baseline_y, points, left_cx, right_cx, left_slope, right_slope, result):
    vis = img.copy()
    h, w = vis.shape[:2]

    # Draw baseline
    cv2.line(vis, (0, baseline_y), (w, baseline_y), (0, 255, 0), 2)

    # Draw contour points
    for x, y in points:
        cv2.circle(vis, (int(x), int(y)), 1, (255, 0, 0), -1)

    # Draw contact points
    if left_cx:
        cv2.circle(vis, (int(left_cx), baseline_y), 6, (0, 0, 255), -1)
    if right_cx:
        cv2.circle(vis, (int(right_cx), baseline_y), 6, (0, 0, 255), -1)

    # Draw angle tangent lines in red
    _draw_angle_line(vis, left_cx, baseline_y, left_slope)
    _draw_angle_line(vis, right_cx, baseline_y, right_slope)

    # Draw dotted arc showing the contact angle at each contact point
    _draw_angle_arc(vis, left_cx, baseline_y, left_slope, result["left_angle"], side="left")
    _draw_angle_arc(vis, right_cx, baseline_y, right_slope, result["right_angle"], side="right")

    # Draw droplet width (horizontal) and height (vertical) lines in red
    x_coords = points[:, 0]
    y_coords = points[:, 1]
    x_min, x_max = int(x_coords.min()), int(x_coords.max())
    y_min = int(y_coords.min())  # topmost point of droplet
    y_max = baseline_y           # bottom is the baseline

    droplet_width_px = x_max - x_min
    droplet_height_px = y_max - y_min

    # Convert to mm if calibrated
    def to_mm(px):
        return round(px / PIXELS_PER_MM, 3) if PIXELS_PER_MM else None

    width_mm = to_mm(droplet_width_px)
    height_mm = to_mm(droplet_height_px)

    w_label = f"W: {droplet_width_px}px" + (f" ({width_mm}mm)" if width_mm else "")
    h_label = f"H: {droplet_height_px}px" + (f" ({height_mm}mm)" if height_mm else "")

    # Horizontal width line at the vertical midpoint of the droplet
    y_mid = (y_min + y_max) // 2
    cv2.line(vis, (x_min, y_mid), (x_max, y_mid), (0, 0, 255), 2)
    cv2.putText(vis, w_label, (x_min, y_mid - 8),
                cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 0, 255), 2)

    # Vertical height line at the horizontal midpoint of the droplet
    x_mid_drop = (x_min + x_max) // 2
    cv2.line(vis, (x_mid_drop, y_min), (x_mid_drop, y_max), (0, 0, 255), 2)
    cv2.putText(vis, h_label, (x_mid_drop + 6, y_min + droplet_height_px // 2),
                cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 0, 255), 2)

    result["droplet_width_px"] = droplet_width_px
    result["droplet_height_px"] = droplet_height_px
    result["droplet_width_mm"] = width_mm
    result["droplet_height_mm"] = height_mm

    fig, axes = plt.subplots(1, 2, figsize=(12, 5))
    axes[0].imshow(cv2.cvtColor(vis, cv2.COLOR_BGR2RGB))
    axes[0].set_title("Detected Droplet")
    axes[0].axis("off")

    axes[1].imshow(edges, cmap="gray")
    axes[1].set_title("Edge Map")
    axes[1].axis("off")

    fig.suptitle(
        f"Left: {result['left_angle']:.1f}°  Right: {result['right_angle']:.1f}°  "
        f"Avg: {result['average_angle']:.1f}°  →  {result['classification']}\n"
        f"Width: {result['droplet_width_px']}px   Height: {result['droplet_height_px']}px",
        fontsize=13,
    )
    plt.tight_layout()
    plt.show()
