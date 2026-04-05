#!/usr/bin/env python3
"""Generate Claude Task Runner app icon:
   Claude-style logo center, clock top-left, crescent moon top-right."""

import struct, zlib, os, math

def create_png(width, height, pixels):
    def chunk(ct, data):
        c = ct + data
        return struct.pack('>I', len(data)) + c + struct.pack('>I', zlib.crc32(c) & 0xffffffff)
    raw = b''
    for y in range(height):
        raw += b'\x00'
        for x in range(width):
            i = (y * width + x) * 4
            raw += bytes(pixels[i:i+4])
    return b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b'')

def blend(bg, fg):
    """Alpha-composite fg over bg, both (r,g,b,a)."""
    fa = fg[3] / 255.0
    ba = bg[3] / 255.0
    oa = fa + ba * (1 - fa)
    if oa == 0:
        return (0, 0, 0, 0)
    r = int((fg[0] * fa + bg[0] * ba * (1 - fa)) / oa)
    g = int((fg[1] * fa + bg[1] * ba * (1 - fa)) / oa)
    b = int((fg[2] * fa + bg[2] * ba * (1 - fa)) / oa)
    return (min(255,r), min(255,g), min(255,b), int(oa * 255))

def set_pixel(pixels, w, h, x, y, color):
    if 0 <= x < w and 0 <= y < h:
        i = (y * w + x) * 4
        bg = (pixels[i], pixels[i+1], pixels[i+2], pixels[i+3])
        c = blend(bg, color)
        pixels[i], pixels[i+1], pixels[i+2], pixels[i+3] = c

def draw_circle_filled(pixels, w, h, cx, cy, r, color):
    for y in range(max(0, int(cy-r-2)), min(h, int(cy+r+2))):
        for x in range(max(0, int(cx-r-2)), min(w, int(cx+r+2))):
            dist = math.sqrt((x - cx)**2 + (y - cy)**2)
            if dist <= r:
                aa = max(0, min(1, (r - dist + 0.5)))
                c = (color[0], color[1], color[2], int(color[3] * aa))
                set_pixel(pixels, w, h, x, y, c)

def draw_ring(pixels, w, h, cx, cy, r, thickness, color):
    for y in range(max(0, int(cy-r-thickness)), min(h, int(cy+r+thickness+1))):
        for x in range(max(0, int(cx-r-thickness)), min(w, int(cx+r+thickness+1))):
            dist = math.sqrt((x - cx)**2 + (y - cy)**2)
            inner = r - thickness/2
            outer = r + thickness/2
            if inner - 1 < dist < outer + 1:
                aa = min(max(0, dist - inner + 0.5), 1) * min(max(0, outer - dist + 0.5), 1)
                c = (color[0], color[1], color[2], int(color[3] * aa))
                set_pixel(pixels, w, h, x, y, c)

def draw_line(pixels, w, h, x0, y0, x1, y1, thickness, color):
    length = math.sqrt((x1-x0)**2 + (y1-y0)**2)
    if length == 0:
        return
    dx, dy = (x1-x0)/length, (y1-y0)/length
    half = thickness / 2
    minx = max(0, int(min(x0, x1) - half - 1))
    maxx = min(w, int(max(x0, x1) + half + 2))
    miny = max(0, int(min(y0, y1) - half - 1))
    maxy = min(h, int(max(y0, y1) + half + 2))
    for y in range(miny, maxy):
        for x in range(minx, maxx):
            # Distance from point to line segment
            t = max(0, min(1, ((x-x0)*dx + (y-y0)*dy) / length))
            px, py = x0 + t*(x1-x0), y0 + t*(y1-y0)
            dist = math.sqrt((x-px)**2 + (y-py)**2)
            if dist < half + 1:
                aa = max(0, min(1, half - dist + 0.5))
                c = (color[0], color[1], color[2], int(color[3] * aa))
                set_pixel(pixels, w, h, x, y, c)

def draw_rounded_rect(pixels, w, h, rx, ry, rw, rh, radius, color):
    for y in range(max(0, ry), min(h, ry + rh)):
        for x in range(max(0, rx), min(w, rx + rw)):
            lx, ly = x - rx, y - ry
            dist = 0
            # Check corners
            if lx < radius and ly < radius:
                dist = math.sqrt((lx - radius)**2 + (ly - radius)**2) - radius
            elif lx > rw - radius - 1 and ly < radius:
                dist = math.sqrt((lx - (rw - radius - 1))**2 + (ly - radius)**2) - radius
            elif lx < radius and ly > rh - radius - 1:
                dist = math.sqrt((lx - radius)**2 + (ly - (rh - radius - 1))**2) - radius
            elif lx > rw - radius - 1 and ly > rh - radius - 1:
                dist = math.sqrt((lx - (rw - radius - 1))**2 + (ly - (rh - radius - 1))**2) - radius
            else:
                dist = -1

            if dist < 1:
                aa = max(0, min(1, -dist + 0.5))
                c = (color[0], color[1], color[2], int(color[3] * aa))
                set_pixel(pixels, w, h, x, y, c)

def make_icon(size):
    pixels = [0] * (size * size * 4)
    s = size  # shorthand
    pad = s * 0.08  # padding from edges

    # === BACKGROUND: Rounded square with Claude's warm gradient ===
    corner_r = s * 0.22
    # Dark background similar to Claude app
    draw_rounded_rect(pixels, s, s, 0, 0, s, s, int(corner_r), (18, 18, 28, 255))

    # Subtle inner gradient overlay
    for y in range(s):
        for x in range(s):
            i = (y * s + x) * 4
            if pixels[i+3] > 0:
                # Subtle purple-to-dark gradient
                t = y / s
                r_add = int(8 * (1 - t))
                b_add = int(12 * (1 - t))
                pixels[i] = min(255, pixels[i] + r_add)
                pixels[i+2] = min(255, pixels[i+2] + b_add)

    # === CLAUDE LOGO: The distinctive starburst/sparkle ===
    cx, cy = s * 0.5, s * 0.52
    logo_r = s * 0.22

    # Claude's warm terracotta/orange color
    claude_color = (217, 119, 87, 255)  # Claude's signature warm color
    claude_light = (235, 155, 120, 255)

    # Draw the Claude sparkle - a 4-pointed star with rounded tips
    def draw_sparkle(px, py, star_r, color, num_points=4):
        """Draw a Claude-style sparkle/starburst."""
        tip_r = star_r
        waist_r = star_r * 0.22
        inner_glow_r = star_r * 0.35

        for y in range(max(0, int(py - tip_r - 2)), min(s, int(py + tip_r + 2))):
            for x in range(max(0, int(px - tip_r - 2)), min(s, int(px + tip_r + 2))):
                dx, dy = x - px, y - py
                dist = math.sqrt(dx*dx + dy*dy)

                if dist > tip_r + 1:
                    continue

                angle = math.atan2(dy, dx)
                # Calculate the star boundary at this angle
                # Smooth 4-pointed star
                star_angle = angle * num_points / 2
                cos_val = math.cos(star_angle)
                # Smooth interpolation between waist and tip
                star_boundary = waist_r + (tip_r - waist_r) * (cos_val ** 2)

                if dist < star_boundary:
                    # Inside the star
                    aa = max(0, min(1, (star_boundary - dist) + 0.5))
                    # Brighter toward center
                    brightness = 1.0 + max(0, (1 - dist / tip_r)) * 0.3
                    r = min(255, int(color[0] * brightness))
                    g = min(255, int(color[1] * brightness))
                    b = min(255, int(color[2] * brightness))
                    c = (r, g, b, int(255 * aa))
                    set_pixel(pixels, s, s, x, y, c)

    # Main sparkle
    draw_sparkle(cx, cy, logo_r, claude_color)

    # Inner glow circle
    glow_r = logo_r * 0.28
    draw_circle_filled(pixels, s, s, cx, cy, glow_r, claude_light)

    # Tiny center highlight
    draw_circle_filled(pixels, s, s, cx, cy, glow_r * 0.5, (255, 200, 170, 255))

    # === CLOCK/TIMER - Top Left Corner ===
    clock_cx = s * 0.2
    clock_cy = s * 0.2
    clock_r = s * 0.11
    clock_ring_thick = s * 0.018
    clock_white = (230, 232, 240, 255)
    clock_accent = (124, 106, 255, 255)  # Purple accent

    # Clock face background
    draw_circle_filled(pixels, s, s, clock_cx, clock_cy, clock_r, (30, 30, 46, 240))
    # Clock ring
    draw_ring(pixels, s, s, clock_cx, clock_cy, clock_r, clock_ring_thick, clock_accent)

    # Hour hand (pointing to ~10 o'clock = 300 degrees)
    hour_angle = math.radians(300 - 90)
    hour_len = clock_r * 0.5
    hx = clock_cx + math.cos(hour_angle) * hour_len
    hy = clock_cy + math.sin(hour_angle) * hour_len
    draw_line(pixels, s, s, clock_cx, clock_cy, hx, hy, max(2, s * 0.02), clock_white)

    # Minute hand (pointing to ~12 o'clock = 0 degrees)
    min_angle = math.radians(0 - 90)
    min_len = clock_r * 0.7
    mx = clock_cx + math.cos(min_angle) * min_len
    my = clock_cy + math.sin(min_angle) * min_len
    draw_line(pixels, s, s, clock_cx, clock_cy, mx, my, max(1.5, s * 0.015), clock_white)

    # Center dot
    draw_circle_filled(pixels, s, s, clock_cx, clock_cy, max(2, s*0.015), clock_white)

    # Small tick marks at 12, 3, 6, 9
    for tick_h in [0, 90, 180, 270]:
        ta = math.radians(tick_h - 90)
        t_out = clock_r - clock_ring_thick
        t_in = t_out - s * 0.02
        tx0 = clock_cx + math.cos(ta) * t_in
        ty0 = clock_cy + math.sin(ta) * t_in
        tx1 = clock_cx + math.cos(ta) * t_out
        ty1 = clock_cy + math.sin(ta) * t_out
        draw_line(pixels, s, s, tx0, ty0, tx1, ty1, max(1, s*0.01), (180, 180, 200, 200))

    # === CRESCENT MOON - Top Right Corner ===
    moon_cx = s * 0.8
    moon_cy = s * 0.19
    moon_r = s * 0.1
    moon_yellow = (255, 220, 80, 255)  # Warm yellow
    moon_bright = (255, 235, 140, 255)

    # Draw full circle (moon base)
    draw_circle_filled(pixels, s, s, moon_cx, moon_cy, moon_r, moon_yellow)

    # Cut out the crescent by drawing a dark circle offset to the right
    cut_offset = moon_r * 0.55
    cut_r = moon_r * 0.85
    cut_cx = moon_cx + cut_offset
    cut_cy = moon_cy - cut_offset * 0.3

    # Erase with background color to create crescent
    for y in range(max(0, int(moon_cy - moon_r - 2)), min(s, int(moon_cy + moon_r + 3))):
        for x in range(max(0, int(moon_cx - moon_r - 2)), min(s, int(moon_cx + moon_r + 3))):
            dist_moon = math.sqrt((x - moon_cx)**2 + (y - moon_cy)**2)
            dist_cut = math.sqrt((x - cut_cx)**2 + (y - cut_cy)**2)

            if dist_moon <= moon_r + 0.5 and dist_cut <= cut_r + 0.5:
                # This pixel is in both circles - cut it
                # Anti-alias: how much is in the cut
                cut_aa = max(0, min(1, cut_r - dist_cut + 0.5))
                moon_aa = max(0, min(1, moon_r - dist_moon + 0.5))

                if cut_aa > 0 and moon_aa > 0:
                    i = (y * s + x) * 4
                    erase = min(cut_aa, moon_aa)
                    # Blend toward background
                    bg = (18, 18, 28)
                    pixels[i] = int(pixels[i] * (1 - erase) + bg[0] * erase)
                    pixels[i+1] = int(pixels[i+1] * (1 - erase) + bg[1] * erase)
                    pixels[i+2] = int(pixels[i+2] * (1 - erase) + bg[2] * erase)

    # Subtle glow on the crescent edge
    for y in range(max(0, int(moon_cy - moon_r - 4)), min(s, int(moon_cy + moon_r + 5))):
        for x in range(max(0, int(moon_cx - moon_r - 4)), min(s, int(moon_cx + moon_r + 5))):
            dist_moon = math.sqrt((x - moon_cx)**2 + (y - moon_cy)**2)
            dist_cut = math.sqrt((x - cut_cx)**2 + (y - cut_cy)**2)
            if dist_moon <= moon_r and dist_cut > cut_r:
                edge_glow = max(0, 1 - abs(dist_moon - moon_r + 2) / 3)
                if edge_glow > 0:
                    c = (255, 245, 200, int(40 * edge_glow))
                    set_pixel(pixels, s, s, x, y, c)

    # Small stars near the moon
    star_positions = [
        (s * 0.73, s * 0.1, s * 0.008),
        (s * 0.88, s * 0.12, s * 0.006),
        (s * 0.86, s * 0.27, s * 0.007),
    ]
    for sx, sy, sr in star_positions:
        draw_circle_filled(pixels, s, s, sx, sy, sr, (255, 255, 220, 180))
        # Tiny cross glow
        glen = sr * 3
        draw_line(pixels, s, s, sx - glen, sy, sx + glen, sy, max(1, sr * 0.6), (255, 255, 220, 60))
        draw_line(pixels, s, s, sx, sy - glen, sx, sy + glen, max(1, sr * 0.6), (255, 255, 220, 60))

    return create_png(s, s, pixels)


# === Generate iconset ===
iconset_dir = os.path.expanduser('~/claude-auto/app/AppIcon.iconset')
os.makedirs(iconset_dir, exist_ok=True)

icon_sizes = [
    (16, 1), (16, 2), (32, 1), (32, 2),
    (128, 1), (128, 2), (256, 1), (256, 2),
    (512, 1), (512, 2)
]

for base, scale in icon_sizes:
    actual = base * scale
    print(f'  Generating {actual}x{actual}...')
    png = make_icon(actual)
    suffix = f'_{base}x{base}{"@2x" if scale == 2 else ""}.png'
    path = os.path.join(iconset_dir, f'icon{suffix}')
    with open(path, 'wb') as f:
        f.write(png)

print('All icon sizes generated.')
