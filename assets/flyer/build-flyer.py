#!/usr/bin/env python3
"""Assemble the workshop flyer: reversed logos + inline QR + template.

Driven by build-flyer.sh; not usually run directly. No third-party imports, so
it works on a stock macOS/Linux python3.
"""
import argparse, base64, pathlib, re, sys


def reversed_aws(src, dst, pnglib):
    """Navy wordmark -> white, orange smile untouched, alpha preserved."""
    w, h, px = pnglib.read_rgba(str(src))
    for i in range(0, len(px), 4):
        r, g, b, a = px[i], px[i+1], px[i+2], px[i+3]
        if a == 0:
            continue
        if not (r > 150 and g > 90 and b < 110):   # not the orange smile
            px[i] = px[i+1] = px[i+2] = 255
    pnglib.write_rgba(str(dst), w, h, px)


def reversed_hashicorp(src, dst, pnglib):
    """Black hexagon on a solid white field -> transparent white mark.

    Luminance drives alpha, so the anti-aliased edges survive the key-out.
    """
    w, h, px = pnglib.read_rgba(str(src))
    for i in range(0, len(px), 4):
        lum = 0.2126*px[i] + 0.7152*px[i+1] + 0.0722*px[i+2]
        px[i] = px[i+1] = px[i+2] = 255
        px[i+3] = max(0, min(255, int(round(255 - lum))))
    pnglib.write_rgba(str(dst), w, h, px)


def qr_to_path(svg_text):
    """Collapse qrencode's per-module <rect> grid into one <path>."""
    dark = set()
    size = 0
    for m in re.finditer(r'<rect[^>]*x="(\d+)"[^>]*y="(\d+)"[^>]*width="(\d+)"[^>]*height="(\d+)"', svg_text):
        x, y, w, h = map(int, m.groups())
        if w > 40 or h > 40:          # the background rect, not a module
            size = max(size, w, h)
            continue
        for yy in range(y, y+h):
            for xx in range(x, x+w):
                dark.add((xx, yy))
    if not dark:
        raise SystemExit("FATAL: no QR modules parsed from qrencode output")
    size = size or (max(x for x, _ in dark) + 1)
    d = []
    for y in range(size):
        x = 0
        while x < size:
            if (x, y) in dark:
                run = 1
                while (x+run, y) in dark:
                    run += 1
                d.append(f"M{x} {y}h{run}v1h-{run}z")
                x += run
            else:
                x += 1
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="-2 -2 {size+4} {size+4}" '
            f'shape-rendering="crispEdges" role="img" aria-label="Workshop URL QR code">'
            f'<path fill="#0d1117" d="{"".join(d)}"/></svg>')


def main():
    ap = argparse.ArgumentParser()
    for f in ("repo", "here", "work", "url", "out"):
        ap.add_argument(f"--{f}", required=True)
    a = ap.parse_args()
    here, repo, work = pathlib.Path(a.here), pathlib.Path(a.repo), pathlib.Path(a.work)

    sys.path.insert(0, str(here))
    import pnglib

    reversed_aws(repo/"assets"/"aws-logo.png", work/"aws.png", pnglib)
    reversed_hashicorp(repo/"assets"/"hashicorp_logo.png", work/"hcp.png", pnglib)

    tpl = (here/"flyer.template.html").read_text()
    out = (tpl
           .replace("__AWS_LOGO__", base64.b64encode((work/"aws.png").read_bytes()).decode())
           .replace("__HASHICORP_LOGO__", base64.b64encode((work/"hcp.png").read_bytes()).decode())
           .replace("__QR__", qr_to_path((work/"qr.svg").read_text()))
           .replace("__WORKSHOP_URL__", a.url)
           .replace("__WORKSHOP_URL_DISPLAY__", re.sub(r"^https://", "", a.url)))

    left = [m for m in ("__AWS_LOGO__", "__HASHICORP_LOGO__", "__QR__", "__WORKSHOP_URL__") if m in out]
    if left:
        raise SystemExit(f"FATAL: placeholders not substituted: {left}")
    pathlib.Path(a.out).write_text(out)


if __name__ == "__main__":
    main()
