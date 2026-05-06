#!/usr/bin/env python3
"""Convert Excalidraw JSON files to sketchy hand-drawn SVGs."""

import json
import html
import math
import random
from pathlib import Path

# Seed for reproducible sketchy output
random.seed(42)

FONT = "Segoe Print, Comic Sans MS, Caveat, cursive"
JITTER = 2.0  # max pixel offset for hand-drawn wobble


def jit(v, amount=JITTER):
    """Add random jitter to a coordinate."""
    return v + random.uniform(-amount, amount)


def parse_color(bg):
    if not bg or bg == "transparent":
        return "none"
    return bg


def sketchy_line(x1, y1, x2, y2, seed_offset=0):
    """Return a wobbly cubic bezier path between two points."""
    dx, dy = x2 - x1, y2 - y1
    length = math.hypot(dx, dy)
    # Perpendicular offset for control points
    nx, ny = -dy, dx
    if length > 0:
        nx, ny = nx / length, ny / length
    bow = min(length * 0.04, 3.5)
    # Two passes like rough.js
    paths = []
    for p in range(2):
        offset = (p - 0.5) * 0.6
        sx = jit(x1, 1.5) + offset
        sy = jit(y1, 1.5) + offset
        ex = jit(x2, 1.5) + offset
        ey = jit(y2, 1.5) + offset
        c1x = x1 + dx * 0.3 + nx * jit(bow, bow * 0.5)
        c1y = y1 + dy * 0.3 + ny * jit(bow, bow * 0.5)
        c2x = x1 + dx * 0.7 + nx * jit(-bow, bow * 0.5)
        c2y = y1 + dy * 0.7 + ny * jit(-bow, bow * 0.5)
        paths.append(f"M {sx:.1f} {sy:.1f} C {c1x:.1f} {c1y:.1f}, {c2x:.1f} {c2y:.1f}, {ex:.1f} {ey:.1f}")
    return " ".join(paths)


def sketchy_rect_path(x, y, w, h, rx=0):
    """Build a sketchy rectangle as a multi-stroke path."""
    corners = [(x, y), (x + w, y), (x + w, y + h), (x, y + h)]
    d = ""
    for i in range(4):
        x1, y1 = corners[i]
        x2, y2 = corners[(i + 1) % 4]
        d += sketchy_line(x1, y1, x2, y2, i) + " "
    return d.strip()


def render_rect(el):
    """Render a sketchy rectangle."""
    x, y = el["x"], el["y"]
    w, h = el["width"], el["height"]
    stroke = el.get("strokeColor", "#000000")
    fill = parse_color(el.get("backgroundColor"))
    sw = el.get("strokeWidth", 1)

    parts = []
    # Fill with a clean rect (background)
    if fill != "none":
        rx = 6 if el.get("roundness") else 0
        parts.append(
            f'  <rect x="{x}" y="{y}" width="{w}" height="{h}" '
            f'rx="{rx}" ry="{rx}" fill="{fill}" stroke="none"/>'
        )
    # Sketchy stroke on top
    d = sketchy_rect_path(x, y, w, h)
    parts.append(
        f'  <path d="{d}" fill="none" stroke="{stroke}" '
        f'stroke-width="{sw}" stroke-linecap="round" stroke-linejoin="round"/>'
    )
    return "\n".join(parts)


def render_text(el):
    """Render text with a handwriting font."""
    x, y = el["x"], el["y"]
    w, h = el["width"], el["height"]
    font_size = el.get("fontSize", 16)
    color = el.get("strokeColor", "#000000")
    text = el.get("text", "")
    align = el.get("textAlign", "center")
    v_align = el.get("verticalAlign", "top")

    lines = text.split("\n")
    line_h = font_size * el.get("lineHeight", 1.25)

    if align == "center":
        anchor, tx = "middle", x + w / 2
    elif align == "right":
        anchor, tx = "end", x + w
    else:
        anchor, tx = "start", x

    total_text_h = len(lines) * line_h
    if v_align == "middle":
        start_y = y + (h - total_text_h) / 2 + font_size * 0.85
    else:
        start_y = y + font_size * 0.85

    parts = [
        f'  <g font-family="{FONT}" font-size="{font_size}" '
        f'fill="{color}" text-anchor="{anchor}">'
    ]
    for i, line in enumerate(lines):
        ly = start_y + i * line_h
        parts.append(f'    <text x="{tx:.1f}" y="{ly:.1f}">{html.escape(line)}</text>')
    parts.append("  </g>")
    return "\n".join(parts)


def sketchy_arrowhead(tip_x, tip_y, dx, dy, size=12):
    """Draw a hand-drawn arrowhead pointing in direction (dx, dy)."""
    length = math.hypot(dx, dy)
    if length == 0:
        return ""
    ux, uy = dx / length, dy / length
    px, py = -uy, ux  # perpendicular

    # Two barb endpoints
    b1x = tip_x - ux * size + px * size * 0.4
    b1y = tip_y - uy * size + py * size * 0.4
    b2x = tip_x - ux * size - px * size * 0.4
    b2y = tip_y - uy * size - py * size * 0.4

    # Sketchy lines from tip to each barb
    d1 = sketchy_line(tip_x, tip_y, jit(b1x, 1), jit(b1y, 1))
    d2 = sketchy_line(tip_x, tip_y, jit(b2x, 1), jit(b2y, 1))
    return f'  <path d="{d1} {d2}" fill="none" stroke="#000000" stroke-width="2" stroke-linecap="round"/>'


def render_arrow(el):
    """Render a sketchy arrow."""
    x, y = el["x"], el["y"]
    points = el.get("points", [[0, 0], [0, 0]])
    stroke = el.get("strokeColor", "#000000")
    sw = el.get("strokeWidth", 2)

    # Defensive branch (RESEARCH §Pitfall 6): handle malformed exports
    if len(points) < 2:
        print(f"  WARN: arrow {el.get('id', '<no-id>')} has < 2 points; skipping")
        return ""

    abs_points = [(x + p[0], y + p[1]) for p in points]

    parts = []
    # Draw sketchy line segments
    for i in range(len(abs_points) - 1):
        x1, y1 = abs_points[i]
        x2, y2 = abs_points[i + 1]
        d = sketchy_line(x1, y1, x2, y2)
        parts.append(
            f'  <path d="{d}" fill="none" stroke="{stroke}" '
            f'stroke-width="{sw}" stroke-linecap="round"/>'
        )

    # Arrowhead
    end_head = el.get("endArrowhead", "arrow")
    if end_head == "arrow" and len(abs_points) >= 2:
        tip_x, tip_y = abs_points[-1]
        prev_x, prev_y = abs_points[-2]
        dx, dy = tip_x - prev_x, tip_y - prev_y
        parts.append(sketchy_arrowhead(tip_x, tip_y, dx, dy))

    return "\n".join(parts)


def convert(input_path, output_path):
    """Convert an Excalidraw file to a sketchy SVG."""
    random.seed(42)  # reset per file for reproducibility

    with open(input_path) as f:
        data = json.load(f)

    elements = [e for e in data.get("elements", []) if not e.get("isDeleted")]

    min_x = min_y = float("inf")
    max_x = max_y = float("-inf")
    for el in elements:
        ex, ey = el["x"], el["y"]
        ew, eh = el.get("width", 0), el.get("height", 0)
        if el["type"] == "arrow":
            for p in el.get("points", []):
                px, py = ex + p[0], ey + p[1]
                min_x, min_y = min(min_x, px), min(min_y, py)
                max_x, max_y = max(max_x, px), max(max_y, py)
        else:
            min_x, min_y = min(min_x, ex), min(min_y, ey)
            max_x, max_y = max(max_x, ex + ew), max(max_y, ey + eh)

    padding = 25
    vb_x = min_x - padding
    vb_y = min_y - padding
    vb_w = (max_x - min_x) + 2 * padding
    vb_h = (max_y - min_y) + 2 * padding

    bg = data.get("appState", {}).get("viewBackgroundColor", "#ffffff")

    svg_parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{vb_x:.0f} {vb_y:.0f} {vb_w:.0f} {vb_h:.0f}" width="{vb_w:.0f}" height="{vb_h:.0f}">',
        f'  <rect x="{vb_x:.0f}" y="{vb_y:.0f}" width="{vb_w:.0f}" height="{vb_h:.0f}" fill="{bg}"/>',
    ]

    rects = [e for e in elements if e["type"] == "rectangle"]
    arrows = [e for e in elements if e["type"] == "arrow"]
    texts = [e for e in elements if e["type"] == "text"]

    for el in rects:
        svg_parts.append(render_rect(el))
    for el in arrows:
        svg_parts.append(render_arrow(el))
    for el in texts:
        svg_parts.append(render_text(el))

    svg_parts.append("</svg>")

    with open(output_path, "w") as f:
        f.write("\n".join(svg_parts))

    print(f"  {input_path} -> {output_path}")


def main():
    # Repo layout: <repo>/infrastructure/scripts/<this file>, assets at <repo>/assets
    root = Path(__file__).resolve().parent.parent.parent
    assets = root / "assets"
    assets.mkdir(exist_ok=True)
    files = [
        "architecture-overview",
        "uc1-flow",
        "uc2-oauth-flow",
        "uc3-ciba-flow",
        "audit-correlation",
        "verify-vault-split",
    ]
    for name in files:
        src = assets / f"{name}.excalidraw"
        dst = assets / f"{name}.svg"
        if src.exists():
            convert(str(src), str(dst))
        else:
            print(f"  SKIP: {src} not found")


if __name__ == "__main__":
    main()
