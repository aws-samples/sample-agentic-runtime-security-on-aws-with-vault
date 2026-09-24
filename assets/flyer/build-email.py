#!/usr/bin/env python3
"""Render email.template.html into email-flyer.html — the flyer as an Outlook-safe
HTML email body.

Why a SEPARATE template instead of reusing workshop-flyer.html: Outlook on
Windows lays out mail with the Word engine, not a browser. It ignores CSS grid,
flexbox, float, border-radius, background gradients and background-clip — the
print flyer is built on all of them, so pasting it produces an unstyled wall of
text. email.template.html rebuilds the same content under the rules Word
honours: nested tables for layout, the bgcolor ATTRIBUTE on every coloured cell
(Word drops background-color on block elements but honours bgcolor), every style
inline, square corners, no web fonts.

Two things cannot be reproduced and are approximated deliberately:
  * the gradient headline — no engine can clip a gradient to text in mail, so
    the words are individually coloured along the same purple→pink→orange ramp.
  * the QR — emitted as a PNG, not the flyer's SVG, because Word cannot render
    SVG at all.

The logos and the QR come from exactly the same sources the print flyer uses, so
the two artefacts cannot drift apart.
"""
import argparse
import base64
import importlib.util
import pathlib
import re
import subprocess
import sys


def load_flyer_module(here):
    """Import build-flyer.py despite the dash in its filename."""
    spec = importlib.util.spec_from_file_location("build_flyer", here / "build-flyer.py")
    mod = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(here))          # build-flyer.py imports pnglib
    spec.loader.exec_module(mod)
    return mod


def main():
    ap = argparse.ArgumentParser()
    for f in ("repo", "here", "work", "url", "out"):
        ap.add_argument(f"--{f}", required=True)
    a = ap.parse_args()
    here, repo, work = pathlib.Path(a.here), pathlib.Path(a.repo), pathlib.Path(a.work)

    import pnglib
    flyer = load_flyer_module(here)

    # Same reversed-out marks the print flyer uses, from the same PNGs.
    flyer.reversed_aws(repo / "assets" / "aws-logo.png", work / "aws.png", pnglib)
    flyer.reversed_hashicorp(repo / "assets" / "hashicorp_logo.png", work / "hcp.png", pnglib)

    # PNG QR, not SVG: the Word engine cannot render SVG.
    qr_png = work / "qr-email.png"
    subprocess.run(
        ["qrencode", "-o", str(qr_png), "-s", "6", "-m", "0", "-l", "M", a.url],
        check=True,
    )

    b64 = lambda p: base64.b64encode(p.read_bytes()).decode()
    tpl = (here / "email.template.html").read_text()
    out = (tpl
           .replace("__AWS_LOGO__", b64(work / "aws.png"))
           .replace("__HASHICORP_LOGO__", b64(work / "hcp.png"))
           .replace("__QR_PNG__", b64(qr_png))
           .replace("__WORKSHOP_URL_DISPLAY__", re.sub(r"^https://", "", a.url))
           .replace("__WORKSHOP_URL__", a.url))

    left = [m for m in ("__AWS_LOGO__", "__HASHICORP_LOGO__", "__QR_PNG__",
                        "__WORKSHOP_URL__", "__WORKSHOP_URL_DISPLAY__") if m in out]
    if left:
        raise SystemExit(f"FATAL: placeholders not substituted: {left}")
    pathlib.Path(a.out).write_text(out)


if __name__ == "__main__":
    main()
