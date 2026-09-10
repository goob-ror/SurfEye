import cv2
import numpy as np
import matplotlib.pyplot as plt

from config import ANGLE_LINE_LENGTH, PIXELS_PER_MM
from core.preprocessor import preprocess, crop_to_roi
from core.tilt_correction import correct_tilt
from core.baseline import detect_baseline, detect_baseline_percentile
from core.contour import extract_droplet_contour, create_circular_mask, create_rectangular_mask
from core.circle_detector import detect_droplet_circle
from core.fitting import (
    fit_droplet_profile, tangent_slope_at, fit_circle,
    fit_ellipse_to_droplet, compute_ellipse_contact_angle
)
from core.angle import compute_contact_angle, classify_surface, compute_contact_angle_from_circle


def run(
    image_path: str, 
    visualize: bool = True, 
    baseline_y_override: int | None = None, 
    droplet_bbox: tuple[float, float, float, float] | None = None, 
    use_ellipse: bool = True,
    brightness: int = 0,
    contrast: float = 1.0,
    edge_sensitivity: int = 50,
    ellipse_adjustments: dict | None = None,
) -> dict:
    """
    Run the complete contact angle measurement pipeline.
    
    Pipeline steps:
    1. Tilt correction - rotate to level the substrate
    2. ROI crop - keep only droplet region, exclude far background
    3. Adaptive thresholding / edge detection on ROI
    4. Blob filter - remove small noise (already in clean_edges)
    5. Geometric baseline fitting - 10th percentile method
    6. Ellipse fit to droplet contour above baseline
    7. Compute tangent angle at contact points → WCA
    
    Args:
        image_path: Path to input image
        visualize: Whether to display matplotlib visualization
        baseline_y_override: Manual baseline y-coordinate (optional)
        droplet_bbox: Manual bounding box as (x1, y1, x2, y2) normalized coords (optional)
        use_ellipse: Use ellipse fitting (True) or polynomial fitting (False)
        brightness: Brightness adjustment in range [-100, 100] (default 0)
        contrast: Contrast multiplier in range [0.5, 3.0] (default 1.0)
        edge_sensitivity: Canny edge detection threshold (param1 for HoughCircles, default 50)
        ellipse_adjustments: Dict with optional keys 'angle', 'scale_a', 'scale_b' for fine-tuning
        
    Returns:
        Dictionary with analysis results including contact angles and metadata
    """
    # Compute Canny thresholds from edge_sensitivity
    # Higher sensitivity = lower thresholds = more edges detected
    canny_low = max(10, 100 - edge_sensitivity)
    canny_high = max(20, 200 - edge_sensitivity)
    
    # STEP 1: Preprocess - load image and initial edge detection with adjustments
    img, edges, roi_bounds = preprocess(
        image_path, 
        apply_roi=True,
        brightness=brightness,
        contrast=contrast,
        canny_threshold_low=canny_low,
        canny_threshold_high=canny_high,
    )
    original_h, original_w = img.shape[:2]
    
    # STEP 2: Tilt correction - rotate image to level substrate
    img_corrected, edges_corrected, tilt_angle = correct_tilt(img, edges)
    
    # STEP 3: ROI crop - apply to corrected images
    # Note: ROI bounds were detected on original image, need to apply carefully
    # For simplicity, re-detect ROI on corrected image
    if roi_bounds is not None:
        gray_corrected = cv2.cvtColor(img_corrected, cv2.COLOR_BGR2GRAY)
        from core.preprocessor import detect_roi_bounds
        roi_bounds = detect_roi_bounds(gray_corrected, padding=50)
        img_roi = crop_to_roi(img_corrected, roi_bounds)
        edges_roi = crop_to_roi(edges_corrected, roi_bounds)
    else:
        img_roi = img_corrected
        edges_roi = edges_corrected
        roi_bounds = (0, 0, img_corrected.shape[1], img_corrected.shape[0])
    
    h, w = img_roi.shape[:2]
    roi_x_offset, roi_y_offset = roi_bounds[0], roi_bounds[1]

    # STEP 4: Blob filtering is already done in clean_edges() in preprocessor
    
    # STEP 5: Detect baseline
    # First try to get a rough baseline using legacy method for initial contour extraction
    detected_baseline_y = detect_baseline(edges_roi)
    
    # Determine initial baseline
    if baseline_y_override is not None:
        # Adjust override for ROI offset
        baseline_y_initial = baseline_y_override - roi_y_offset
    elif detected_baseline_y is not None:
        baseline_y_initial = detected_baseline_y
    else:
        # Fallback to bottom 10% of image
        baseline_y_initial = int(h * 0.9)

    # STEP 6: Extract droplet contour (with optional ROI masking for circle detection)
    roi_mask = None
    circle_metadata = None
    detection_method = "full_contour"

    # Convert normalized bbox coordinates to pixel coordinates if provided
    if droplet_bbox is not None:
        x1, y1, x2, y2 = droplet_bbox
        # These are relative to the ROI-cropped image
        x1_px = int(x1 * w)
        y1_px = int(y1 * h)
        x2_px = int(x2 * w)
        y2_px = int(y2 * h)
        
        roi_mask = create_rectangular_mask(edges_roi.shape, x1_px, y1_px, x2_px, y2_px)
        search_edges = cv2.bitwise_and(edges_roi, edges_roi, mask=roi_mask)
        detection_method = "manual_bbox"
    else:
        search_edges = edges_roi

    # Try circle detection
    gray_roi = cv2.cvtColor(img_roi, cv2.COLOR_BGR2GRAY)
    circle = detect_droplet_circle(gray_roi, search_edges)

    if circle is not None:
        cx, cy, radius = circle
        roi_mask = create_circular_mask(edges_roi.shape, cx, cy, radius)
        circle_metadata = {
            "center_x": int(cx),
            "center_y": int(cy),
            "radius": int(radius),
        }
        detection_method = "circle_constrained"

    # Extract contour
    points = extract_droplet_contour(edges_roi, baseline_y_initial, roi_mask=roi_mask)
    if points is None:
        raise RuntimeError("Could not extract droplet contour.")

    # STEP 5 (refined): Use 10th percentile method on actual contour points
    baseline_y_percentile = detect_baseline_percentile(points, percentile=10.0)
    
    if baseline_y_percentile is not None:
        baseline_y = baseline_y_percentile
    else:
        baseline_y = baseline_y_initial
    
    # Override if user provided manual baseline
    if baseline_y_override is not None:
        baseline_y = baseline_y_override - roi_y_offset

    # Re-extract contour with refined baseline if it changed significantly
    if abs(baseline_y - baseline_y_initial) > 5:
        points = extract_droplet_contour(edges_roi, baseline_y, roi_mask=roi_mask)
        if points is None:
            # Fall back to original points
            points = extract_droplet_contour(edges_roi, baseline_y_initial, roi_mask=roi_mask)
            baseline_y = baseline_y_initial

    # STEP 6 & 7: Fit ellipse or polynomial and compute contact angles
    if use_ellipse:
        # Ellipse fitting method (PREFERRED)
        ellipse_fit = fit_ellipse_to_droplet(points, baseline_y)
        
        if ellipse_fit is None:
            raise RuntimeError("Ellipse fitting failed — not enough contour points.")
        
        # Extract ellipse parameters
        cx, cy = ellipse_fit['center']
        major_axis, minor_axis = ellipse_fit['axes']
        angle_deg = ellipse_fit['angle']
        
        # Apply ellipse adjustments if provided
        if ellipse_adjustments:
            if ellipse_adjustments.get('angle') is not None:
                angle_deg += ellipse_adjustments['angle']
            if ellipse_adjustments.get('scale_a') is not None:
                major_axis *= ellipse_adjustments['scale_a']
            if ellipse_adjustments.get('scale_b') is not None:
                minor_axis *= ellipse_adjustments['scale_b']
        
        # Recalculate contact points with adjusted ellipse
        from core.fitting import find_ellipse_baseline_intersection
        intersections = find_ellipse_baseline_intersection(
            cx, cy, major_axis, minor_axis, angle_deg, baseline_y
        )
        
        if intersections is None:
            raise RuntimeError("Could not find ellipse-baseline intersections with adjusted parameters.")
        
        left_contact = intersections[0]
        right_contact = intersections[1]
        
        # Compute contact angles using ellipse geometry
        left_angle = compute_ellipse_contact_angle(
            cx, cy, major_axis, minor_axis, angle_deg,
            left_contact[0], baseline_y
        )
        right_angle = compute_ellipse_contact_angle(
            cx, cy, major_axis, minor_axis, angle_deg,
            right_contact[0], baseline_y
        )
        
        result = classify_surface(left_angle, right_angle)
        result["method"] = "ellipse"
        result["ellipse_fit"] = {
            "center": (float(cx), float(cy)),
            "major_axis": float(major_axis),
            "minor_axis": float(minor_axis),
            "angle": float(angle_deg)
        }
        result["left_contact_x"] = left_contact[0]
        result["right_contact_x"] = right_contact[0]
        
    else:
        # Polynomial fitting method (LEGACY)
        left_fit, right_fit, left_cx, right_cx = fit_droplet_profile(points, baseline_y)
        if left_fit is None or right_fit is None:
            raise RuntimeError("Polynomial fitting failed — not enough contour points.")

        # Compute tangent slopes at contact points
        left_slope = tangent_slope_at(left_fit, baseline_y)
        right_slope = tangent_slope_at(right_fit, baseline_y)

        # Compute contact angles
        left_angle = compute_contact_angle(left_slope, side="left")
        right_angle = compute_contact_angle(right_slope, side="right")

        result = classify_surface(left_angle, right_angle)
        result["method"] = "polynomial"
        result["left_contact_x"] = left_cx
        result["right_contact_x"] = right_cx
        result["left_slope"] = left_slope
        result["right_slope"] = right_slope

    # Add common metadata
    result["detected_baseline_y"] = detected_baseline_y + roi_y_offset if detected_baseline_y else None
    result["baseline_y"] = baseline_y + roi_y_offset  # Convert back to original image coordinates
    result["baseline_y_roi"] = baseline_y  # Keep ROI-relative coordinate for visualization
    result["detection_method"] = detection_method
    result["tilt_angle"] = float(tilt_angle)
    result["roi_bounds"] = roi_bounds
    result["tilt_corrected"] = abs(tilt_angle) > 0.1
    
    if circle_metadata:
        result["circle_detection"] = circle_metadata

    # Compute droplet dimensions
    x_coords = points[:, 0]
    y_coords = points[:, 1]
    x_min, x_max = int(x_coords.min()), int(x_coords.max())
    y_min = int(y_coords.min())
    
    droplet_width_px = x_max - x_min
    droplet_height_px = baseline_y - y_min

    def to_mm(px):
        return round(px / PIXELS_PER_MM, 3) if PIXELS_PER_MM else None

    result["droplet_width_px"] = droplet_width_px
    result["droplet_height_px"] = droplet_height_px
    result["droplet_width_mm"] = to_mm(droplet_width_px)
    result["droplet_height_mm"] = to_mm(droplet_height_px)

    # Save images as WebP for better compression
    import os
    base, ext = os.path.splitext(image_path)
    edge_image_path = base + "_edges.webp"
    cv2.imwrite(edge_image_path, edges_roi, [cv2.IMWRITE_WEBP_QUALITY, 90])
    result["edge_image_path"] = edge_image_path

    # Generate and save annotated visualization as WebP
    annotated_image_path = base + "_annotated.webp"
    _visualize_to_file(img_roi, edges_roi, baseline_y, points, result, annotated_image_path)
    result["annotated_image_path"] = annotated_image_path

    if visualize:
        _visualize(img_roi, edges_roi, baseline_y, points, result)

    return result


def _draw_angle_arc_ellipse(vis, contact_x, baseline_y, angle_deg, side="left", arc_radius=40):
    """
    Draw a purple dotted arc showing the contact angle (for ellipse method).
    Simplified version since we already have the angle computed.
    """
    if contact_x is None:
        return
    cx, cy = int(contact_x), baseline_y

    # The angle is already computed correctly, just draw the arc
    if side == "left":
        arc_start = 0.0
        arc_end = angle_deg
    else:
        arc_start = 180.0 - angle_deg
        arc_end = 180.0

    _draw_dotted_arc(vis, cx, cy, arc_radius, arc_start, arc_end)

    mid_angle = np.radians((arc_start + arc_end) / 2)
    lx = int(cx + (arc_radius + 18) * np.cos(mid_angle))
    ly = int(cy - (arc_radius + 18) * np.sin(mid_angle))
    cv2.putText(vis, f"{angle_deg:.1f}", (lx - 15, ly),
                cv2.FONT_HERSHEY_SIMPLEX, 0.55, (128, 0, 128), 2)


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


def _visualize_to_file(img, edges, baseline_y, points, result, output_path: str):
    """Generate annotated visualization and save to file without displaying."""
    vis = img.copy()
    h, w = vis.shape[:2]

    # Draw baseline
    cv2.line(vis, (0, baseline_y), (w, baseline_y), (0, 255, 0), 2)

    # Draw contour points
    for x, y in points:
        cv2.circle(vis, (int(x), int(y)), 1, (255, 0, 0), -1)

    method = result.get("method", "polynomial")
    
    if method == "ellipse":
        # Draw ellipse fit
        ellipse_params = result["ellipse_fit"]
        cx, cy = ellipse_params["center"]
        major = ellipse_params["major_axis"]
        minor = ellipse_params["minor_axis"]
        angle = ellipse_params["angle"]
        
        # Draw ellipse
        cv2.ellipse(
            vis,
            (int(cx), int(cy)),
            (int(major), int(minor)),
            angle,
            0, 360,
            (255, 200, 0), 2
        )
        
        # Draw contact points
        left_cx = result.get("left_contact_x")
        right_cx = result.get("right_contact_x")
        
        if left_cx is not None:
            cv2.circle(vis, (int(left_cx), baseline_y), 6, (0, 0, 255), -1)
        if right_cx is not None:
            cv2.circle(vis, (int(right_cx), baseline_y), 6, (0, 0, 255), -1)
            
        # Draw angle indicators
        left_angle = result["left_angle"]
        right_angle = result["right_angle"]
        _draw_angle_arc_ellipse(vis, int(left_cx) if left_cx else None, baseline_y, left_angle, side="left")
        _draw_angle_arc_ellipse(vis, int(right_cx) if right_cx else None, baseline_y, right_angle, side="right")
        
    else:
        # Polynomial method - draw fitted curves and tangent lines
        left_cx = result.get("left_contact_x")
        right_cx = result.get("right_contact_x")
        left_slope = result.get("left_slope")
        right_slope = result.get("right_slope")
        
        # Draw contact points
        if left_cx is not None:
            cv2.circle(vis, (int(left_cx), baseline_y), 6, (0, 0, 255), -1)
        if right_cx is not None:
            cv2.circle(vis, (int(right_cx), baseline_y), 6, (0, 0, 255), -1)

        # Draw tangent lines
        _draw_angle_line(vis, left_cx, baseline_y, left_slope)
        _draw_angle_line(vis, right_cx, baseline_y, right_slope)

        # Draw angle arcs
        _draw_angle_arc(vis, left_cx, baseline_y, left_slope, result["left_angle"], side="left")
        _draw_angle_arc(vis, right_cx, baseline_y, right_slope, result["right_angle"], side="right")

        # Draw fitted polynomial curves
        x_coords = points[:, 0]
        y_coords = points[:, 1]
        y_min = int(y_coords.min())
        
        from core.fitting import fit_droplet_profile
        left_fit, right_fit, _, _ = fit_droplet_profile(points, baseline_y)
        if left_fit is not None and right_fit is not None:
            y_vals = np.arange(y_min, baseline_y)
            # Left curve
            x_vals_left = np.polyval(left_fit, y_vals).astype(int)
            pts_left = np.column_stack((x_vals_left, y_vals))
            cv2.polylines(vis, [pts_left], isClosed=False, color=(255, 200, 0), thickness=2)
            # Right curve
            x_vals_right = np.polyval(right_fit, y_vals).astype(int)
            pts_right = np.column_stack((x_vals_right, y_vals))
            cv2.polylines(vis, [pts_right], isClosed=False, color=(255, 200, 0), thickness=2)

    # Draw droplet dimensions
    x_coords = points[:, 0]
    y_coords = points[:, 1]
    x_min, x_max = int(x_coords.min()), int(x_coords.max())
    y_min = int(y_coords.min())

    droplet_width_px = result["droplet_width_px"]
    droplet_height_px = result["droplet_height_px"]
    
    width_mm = result.get("droplet_width_mm")
    height_mm = result.get("droplet_height_mm")

    w_label = f"W: {droplet_width_px}px" + (f" ({width_mm}mm)" if width_mm else "")
    h_label = f"H: {droplet_height_px}px" + (f" ({height_mm}mm)" if height_mm else "")

    # Horizontal width line
    y_mid = (y_min + baseline_y) // 2
    cv2.line(vis, (x_min, y_mid), (x_max, y_mid), (0, 0, 255), 2)
    cv2.putText(vis, w_label, (x_min, y_mid - 8),
                cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 0, 255), 2)

    # Vertical height line
    x_mid_drop = (x_min + x_max) // 2
    cv2.line(vis, (x_mid_drop, y_min), (x_mid_drop, baseline_y), (0, 0, 255), 2)
    cv2.putText(vis, h_label, (x_mid_drop + 6, y_min + droplet_height_px // 2),
                cv2.FONT_HERSHEY_SIMPLEX, 0.55, (0, 0, 255), 2)

    # Add tilt angle info if corrected
    if result.get("tilt_corrected", False):
        tilt_text = f"Tilt corrected: {result['tilt_angle']:.2f}°"
        cv2.putText(vis, tilt_text, (10, 30),
                    cv2.FONT_HERSHEY_SIMPLEX, 0.6, (255, 255, 0), 2)

    # If circle was detected, draw it
    if "circle_detection" in result:
        circ = result["circle_detection"]
        cv2.circle(vis, (circ["center_x"], circ["center_y"]), circ["radius"], (0, 255, 255), 1, cv2.LINE_AA)

    # Save annotated image as WebP
    cv2.imwrite(output_path, vis, [cv2.IMWRITE_WEBP_QUALITY, 90])


def _visualize(img, edges, baseline_y, points, result):
    """Display interactive visualization with matplotlib."""
    vis = img.copy()
    h, w = vis.shape[:2]

    # Draw baseline
    cv2.line(vis, (0, baseline_y), (w, baseline_y), (0, 255, 0), 2)

    # Draw contour points
    for x, y in points:
        cv2.circle(vis, (int(x), int(y)), 1, (255, 0, 0), -1)

    method = result.get("method", "polynomial")
    
    if method == "ellipse":
        # Draw ellipse fit
        ellipse_params = result["ellipse_fit"]
        cx, cy = ellipse_params["center"]
        major = ellipse_params["major_axis"]
        minor = ellipse_params["minor_axis"]
        angle = ellipse_params["angle"]
        
        cv2.ellipse(
            vis,
            (int(cx), int(cy)),
            (int(major), int(minor)),
            angle,
            0, 360,
            (255, 200, 0), 2
        )
        
        left_cx = result.get("left_contact_x")
        right_cx = result.get("right_contact_x")
        
        if left_cx is not None:
            cv2.circle(vis, (int(left_cx), baseline_y), 6, (0, 0, 255), -1)
        if right_cx is not None:
            cv2.circle(vis, (int(right_cx), baseline_y), 6, (0, 0, 255), -1)
            
    else:
        # Polynomial method
        left_cx = result.get("left_contact_x")
        right_cx = result.get("right_contact_x")
        left_slope = result.get("left_slope")
        right_slope = result.get("right_slope")
        
        if left_cx is not None:
            cv2.circle(vis, (int(left_cx), baseline_y), 6, (0, 0, 255), -1)
        if right_cx is not None:
            cv2.circle(vis, (int(right_cx), baseline_y), 6, (0, 0, 255), -1)

        _draw_angle_line(vis, left_cx, baseline_y, left_slope)
        _draw_angle_line(vis, right_cx, baseline_y, right_slope)
        _draw_angle_arc(vis, left_cx, baseline_y, left_slope, result["left_angle"], side="left")
        _draw_angle_arc(vis, right_cx, baseline_y, right_slope, result["right_angle"], side="right")

    # If circle was detected, draw it
    if "circle_detection" in result:
        circ = result["circle_detection"]
        cv2.circle(vis, (circ["center_x"], circ["center_y"]), circ["radius"], (0, 255, 255), 1, cv2.LINE_AA)

    fig, axes = plt.subplots(1, 2, figsize=(12, 5))
    axes[0].imshow(cv2.cvtColor(vis, cv2.COLOR_BGR2RGB))
    axes[0].set_title(f"Detected Droplet ({method.capitalize()} Method)")
    axes[0].axis("off")

    axes[1].imshow(edges, cmap="gray")
    axes[1].set_title("Edge Map")
    axes[1].axis("off")

    tilt_info = f"  [Tilt: {result.get('tilt_angle', 0):.2f}°]" if result.get("tilt_corrected", False) else ""
    fig.suptitle(
        f"Left: {result['left_angle']:.1f}°  Right: {result['right_angle']:.1f}°  "
        f"Avg: {result['average_angle']:.1f}°  →  {result['classification']}{tilt_info}\n"
        f"Width: {result['droplet_width_px']}px   Height: {result['droplet_height_px']}px",
        fontsize=13,
    )
    plt.tight_layout()
    plt.show()
