#!/usr/bin/env python3
"""
generate_icon.py

Generates a compliant 1024x1024 iOS universal App Icon for Need for Speed: Carbon.
Features:
- Dark 2x2 twill carbon fiber weave procedural texture
- Radial vignette / rim lighting
- Stylized crimson red NFS "C" insignia with geometric bevels and metallic reflections
- Clean sRGB color space without alpha channel (iOS App Store & actool compliance)
"""

import math
import os
import sys
from PIL import Image, ImageDraw, ImageFilter, ImageFont

def create_carbon_fiber_tile(size=32):
    """Generates a seamless 2x2 twill carbon fiber weave tile."""
    tile = Image.new("RGB", (size, size), (18, 18, 20))
    draw = ImageDraw.Draw(tile)
    half = size // 2
    
    # Weave colors: highlights, midtones, shadows
    c_base = (24, 24, 27)
    c_light = (42, 42, 48)
    c_dark = (10, 10, 12)
    c_mid = (30, 30, 35)

    # Top-left block
    draw.rectangle([0, 0, half, half], fill=c_base)
    for i in range(0, half, 4):
        draw.line([(0, i), (i, 0)], fill=c_light, width=1)
        draw.line([(i, half), (half, i)], fill=c_dark, width=1)

    # Bottom-right block (aligned)
    draw.rectangle([half, half, size, size], fill=c_base)
    for i in range(0, half, 4):
        draw.line([(half, half + i), (half + i, half)], fill=c_light, width=1)
        draw.line([(half + i, size), (size, half + i)], fill=c_dark, width=1)

    # Top-right block (perpendicular weave)
    draw.rectangle([half, 0, size, half], fill=c_mid)
    for i in range(0, half, 4):
        draw.line([(half, half - i), (size - i, 0)], fill=c_dark, width=1)
        draw.line([(half + i, half), (size, i)], fill=c_light, width=1)

    # Bottom-left block (perpendicular weave)
    draw.rectangle([0, half, half, size], fill=c_mid)
    for i in range(0, half, 4):
        draw.line([(0, size - i), (half - i, half)], fill=c_dark, width=1)
        draw.line([(i, size), (half, half + i)], fill=c_light, width=1)

    return tile

def generate_nfs_carbon_icon(output_path: str):
    width, height = 1024, 1024
    
    # 1. Base image
    img = Image.new("RGB", (width, height), (15, 15, 17))
    
    # 2. Tile carbon fiber texture
    tile_size = 32
    tile = create_carbon_fiber_tile(tile_size)
    for y in range(0, height, tile_size):
        for x in range(0, width, tile_size):
            img.paste(tile, (x, y))

    # 3. Apply radial vignette & dark mood lighting
    vignette = Image.new("L", (width, height), 0)
    center_x, center_y = width / 2.0, height / 2.0
    max_radius = math.sqrt(center_x**2 + center_y**2)
    
    vig_draw = ImageDraw.Draw(vignette)
    for r in range(int(max_radius), 0, -8):
        norm = r / max_radius
        # Ambient light at center: subtle metallic spotlight
        alpha = int(255 * (1.0 - (norm ** 1.8)))
        vig_draw.ellipse(
            [center_x - r, center_y - r, center_x + r, center_y + r],
            fill=min(255, alpha)
        )
    vignette = vignette.filter(ImageFilter.GaussianBlur(radius=24))
    
    # Blend subtle spotlight over carbon weave
    spotlight = Image.new("RGB", (width, height), (45, 48, 55))
    img = Image.composite(spotlight, img, vignette)

    # Draw racing angle dark carbon slash accents
    overlay = Image.new("RGBA", (width, height), (0, 0, 0, 0))
    ov_draw = ImageDraw.Draw(overlay)
    
    # Red ambient glow behind the "C"
    glow_mask = Image.new("L", (width, height), 0)
    g_draw = ImageDraw.Draw(glow_mask)
    g_draw.ellipse([260, 260, 764, 764], fill=160)
    glow_mask = glow_mask.filter(ImageFilter.GaussianBlur(radius=75))
    red_ambient = Image.new("RGBA", (width, height), (220, 20, 35, 180))
    overlay.paste(red_ambient, (0, 0), glow_mask)

    # 4. Draw stylized sharp NFS "C" insignia
    # The Carbon "C" has aggressive angled cuts, speed trails, and faceted bevels
    c_outer = [
        (680, 260),
        (460, 260),
        (310, 410),
        (310, 614),
        (460, 764),
        (680, 764),
        (710, 690),
        (510, 690),
        (420, 600),
        (420, 424),
        (510, 334),
        (710, 334)
    ]
    
    c_shadow = [(x + 8, y + 14) for x, y in c_outer]
    ov_draw.polygon(c_shadow, fill=(10, 10, 12, 230))

    # Base vibrant Crimson Red
    crimson_top = (255, 30, 45, 255)
    crimson_bot = (180, 10, 25, 255)
    ov_draw.polygon(c_outer, fill=crimson_top)

    # Bevel lines and inner cuts
    # Top slash highlight
    top_bevel = [
        (680, 260),
        (460, 260),
        (310, 410),
        (390, 410),
        (490, 310),
        (695, 310)
    ]
    ov_draw.polygon(top_bevel, fill=(255, 95, 105, 255))

    # Bottom faceted edge
    bot_bevel = [
        (310, 614),
        (460, 764),
        (680, 764),
        (650, 715),
        (480, 715),
        (380, 614)
    ]
    ov_draw.polygon(bot_bevel, fill=(130, 8, 18, 255))

    # Chrome metallic central divider notch
    notch = [
        (260, 500),
        (410, 500),
        (430, 524),
        (260, 524)
    ]
    ov_draw.polygon(notch, fill=(240, 245, 250, 255))

    # Speed chevron cuts
    for offset_y in (370, 430, 490, 550, 610):
        chevron = [
            (230, offset_y),
            (280, offset_y),
            (260, offset_y + 18),
            (210, offset_y + 18)
        ]
        ov_draw.polygon(chevron, fill=(220, 25, 35, 220))

    # 5. NFS Carbon Wordmark typography
    # "CARBON" bold header font
    try:
        # Try finding system bold sans font
        font = ImageFont.truetype("arialbd.ttf", 64)
        subfont = ImageFont.truetype("arial.ttf", 32)
    except Exception:
        font = ImageFont.load_default()
        subfont = ImageFont.load_default()

    wordmark = "CARBON"
    subtitle = "NEED FOR SPEED"
    
    # Draw drop shadow for text
    ov_draw.text((514, 822), subtitle, fill=(10, 10, 15, 240), font=subfont, anchor="mm")
    ov_draw.text((512, 820), subtitle, fill=(200, 205, 215, 255), font=subfont, anchor="mm")

    ov_draw.text((515, 878), wordmark, fill=(10, 10, 15, 240), font=font, anchor="mm")
    ov_draw.text((512, 874), wordmark, fill=(245, 250, 255, 255), font=font, anchor="mm")

    # Collector's Edition Gold Accent
    edition = "COLLECTOR'S EDITION"
    try:
        gold_font = ImageFont.truetype("arialbd.ttf", 26)
    except Exception:
        gold_font = ImageFont.load_default()
    ov_draw.text((513, 926), edition, fill=(240, 185, 45, 255), font=gold_font, anchor="mm")

    # Composite overlay
    final_img = Image.alpha_composite(img.convert("RGBA"), overlay).convert("RGB")

    # Ensure output directory exists
    icon_dir = os.path.dirname(os.path.abspath(output_path))
    os.makedirs(icon_dir, exist_ok=True)
    
    # Save standard compliant 1024x1024 PNG without alpha
    final_img.save(output_path, "PNG", optimize=True)
    print(f"[SUCCESS] Generated 1024x1024 App Icon at: {output_path}")

    # Generate standard iOS scaled assets
    sizes = {
        "AppIcon.png": (1024, 1024),
        "AppIcon60x60@2x.png": (120, 120),
        "AppIcon60x60@3x.png": (180, 180),
        "AppIcon76x76@2x~ipad.png": (152, 152),
        "AppIcon83.5x83.5@2x~ipad.png": (167, 167),
        "AppIcon20x20@2x.png": (40, 40),
        "AppIcon20x20@3x.png": (60, 60),
        "AppIcon29x29@2x.png": (58, 58),
        "AppIcon29x29@3x.png": (87, 87),
        "AppIcon40x40@2x.png": (80, 80),
        "AppIcon40x40@3x.png": (120, 120),
    }

    for name, (w, h) in sizes.items():
        scaled = final_img.resize((w, h), Image.Resampling.LANCZOS)
        dest = os.path.join(icon_dir, name)
        scaled.save(dest, "PNG", optimize=True)
        print(f"  Generated {name} ({w}x{h})")

if __name__ == "__main__":
    # Determine project root by locating ios/resources
    candidate = os.path.abspath(os.path.dirname(__file__))
    project_root = None
    for _ in range(5):
        if os.path.isdir(os.path.join(candidate, "ios", "resources")):
            project_root = candidate
            break
        parent = os.path.dirname(candidate)
        if parent == candidate:
            break
        candidate = parent
    
    if not project_root:
        project_root = os.getcwd()

    default_dest = os.path.join(
        project_root, "ios", "resources", "Assets.xcassets", "AppIcon.appiconset", "icon-1024.png"
    )
    target = sys.argv[1] if len(sys.argv) > 1 else default_dest
    generate_nfs_carbon_icon(os.path.abspath(target))
