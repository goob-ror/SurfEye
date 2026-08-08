import argparse
import tkinter as tk
from tkinter import filedialog
from pipeline import run


def pick_image() -> str:
    root = tk.Tk()
    root.withdraw()
    path = filedialog.askopenfilename(
        title="Select a droplet image",
        filetypes=[("Image files", "*.jpg *.jpeg *.png *.bmp *.tiff *.tif"), ("All files", "*.*")],
    )
    root.destroy()
    return path

def main():
    parser = argparse.ArgumentParser(description="SurfEye — Contact Angle Measurement")
    parser.add_argument("image", nargs="?", help="Path to the droplet image (optional, opens file dialog if omitted)")
    parser.add_argument("--no-viz", action="store_true", help="Disable visualization")
    args = parser.parse_args()

    image_path = args.image or pick_image()
    if not image_path:
        print("No image selected. Exiting.")
        return

    try:
        result = run(image_path, visualize=not args.no_viz)
    except RuntimeError as e:
        print(f"\nError: {e}")
        print("Tip: Try an image with clear contrast between the droplet and surface.")
        print("     Ensure the surface baseline is visible as a horizontal line.")
        return

    print(f"\n--- Results ---")
    print(f"Method              : {result.get('method', 'polynomial')}")
    print(f"Left contact angle  : {result['left_angle']:.2f}°")
    print(f"Right contact angle : {result['right_angle']:.2f}°")
    print(f"Average             : {result['average_angle']:.2f}°")
    print(f"Classification      : {result['classification']}")
    print(f"Droplet width       : {result.get('droplet_width_px', 'N/A')}px" +
          (f"  ({result['droplet_width_mm']}mm)" if result.get('droplet_width_mm') else ""))
    print(f"Droplet height      : {result.get('droplet_height_px', 'N/A')}px" +
          (f"  ({result['droplet_height_mm']}mm)" if result.get('droplet_height_mm') else ""))

if __name__ == "__main__":
    main()
