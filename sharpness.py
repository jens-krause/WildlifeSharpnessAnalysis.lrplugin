#!/usr/bin/env python3
"""Score photos by sharpness so a caller can pick the sharpest frame of a burst.

Reads a UTF-8 file listing one image path per line, writes one result line per
input to stdout:

    OK<TAB><score><TAB><path>
    ERR<TAB><message><TAB><path>

Scores are only comparable within one burst of the same scene.
"""

import argparse
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
from PIL import Image

DEFAULT_EXIFTOOL = "exiftool"

TILES_X = 18
TILES_Y = 12

# Wildlife backgrounds (grass, branches) are deceptively high-frequency, so a
# whole-image score is dominated by the background instead of the subject. The
# best-focused region is what distinguishes frames of one burst, hence the mean
# over only the few strongest tiles.
TOP_TILES = 3

# Tiles overlapping the camera's AF area get their variance score multiplied
# by this before ranking, so they're more likely to end up among TOP_TILES.
AF_WEIGHT = 3.0

# Embedded JPEGs in preference order: the full-size one first, then the small
# preview, before falling back to decoding the file itself.
EMBEDDED_TAGS = ("JpgFromRaw", "PreviewImage")

AF_TAGS = (
    "ValidAFPoints",
    "AFImageWidth",
    "AFImageHeight",
    "AFAreaXPositions",
    "AFAreaYPositions",
    "AFAreaWidths",
    "AFAreaHeights",
)


def read_af_box(path, exiftool):
    """Return the camera's autofocus area as (left, top, right, bottom)
    fractions of the image, or None if the raw has no single valid AF area.

    Only single-AF-area shots are used: with several valid points there is
    no single spot to trust as "the subject", so the caller falls back to
    scoring the whole image instead of guessing.
    """
    result = subprocess.run(
        [exiftool, "-s3"] + [f"-{tag}" for tag in AF_TAGS] + [str(path)],
        capture_output=True,
        text=True,
    )
    lines = result.stdout.splitlines()
    if result.returncode != 0 or len(lines) != len(AF_TAGS):
        return None

    valid_points, af_width, af_height, x_positions, y_positions, widths, heights = lines
    if valid_points.strip() != "1":
        return None

    try:
        af_width = float(af_width)
        af_height = float(af_height)
        x = float(x_positions.split()[0])
        y = float(y_positions.split()[0])
        w = float(widths.split()[0])
        h = float(heights.split()[0])
    except (ValueError, IndexError):
        return None

    # Canon AF positions are given relative to the image center, with X
    # growing right and Y growing up (i.e. the opposite of pixel-row order).
    center_x = af_width / 2 + x
    center_y = af_height / 2 - y

    return (
        (center_x - w / 2) / af_width,
        (center_y - h / 2) / af_height,
        (center_x + w / 2) / af_width,
        (center_y + h / 2) / af_height,
    )


def extract_embedded_jpeg(path, exiftool, workdir):
    for tag in EMBEDDED_TAGS:
        out = workdir / f"{tag}.jpg"
        with open(out, "wb") as fh:
            result = subprocess.run(
                [exiftool, "-b", "-" + tag, str(path)],
                stdout=fh,
                stderr=subprocess.DEVNULL,
            )
        if result.returncode == 0 and out.stat().st_size > 0:
            return out
    return None


def tile_bounds(length, count):
    edges = np.linspace(0, length, count + 1).astype(int)
    return list(zip(edges[:-1], edges[1:]))


def sharpness_score(image_path, af_box=None):
    with Image.open(image_path) as img:
        gray = np.asarray(img.convert("L"), dtype=np.float32)

    laplacian = (
        -4.0 * gray[1:-1, 1:-1]
        + gray[:-2, 1:-1]
        + gray[2:, 1:-1]
        + gray[1:-1, :-2]
        + gray[1:-1, 2:]
    )
    height, width = laplacian.shape

    af_pixels = None
    if af_box is not None:
        left, top, right, bottom = af_box
        af_pixels = (left * width, top * height, right * width, bottom * height)

    rows = tile_bounds(height, TILES_Y)
    cols = tile_bounds(width, TILES_X)

    tile_scores = []
    for y0, y1 in rows:
        for x0, x1 in cols:
            score = float(laplacian[y0:y1, x0:x1].var())
            if af_pixels is not None:
                af_left, af_top, af_right, af_bottom = af_pixels
                if x1 > af_left and x0 < af_right and y1 > af_top and y0 < af_bottom:
                    score *= AF_WEIGHT
            tile_scores.append(score)

    tile_scores.sort(reverse=True)
    return float(np.mean(tile_scores[:TOP_TILES]))


def score_photo(path, exiftool):
    af_box = read_af_box(path, exiftool)
    with tempfile.TemporaryDirectory() as tmp:
        source = extract_embedded_jpeg(path, exiftool, Path(tmp)) or path
        return sharpness_score(source, af_box)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("listfile", help="file containing one image path per line")
    parser.add_argument("--exiftool", default=DEFAULT_EXIFTOOL)
    args = parser.parse_args()

    paths = [
        line.strip()
        for line in Path(args.listfile).read_text(encoding="utf-8").splitlines()
        if line.strip()
    ]

    for path in paths:
        try:
            score = score_photo(Path(path), args.exiftool)
            print(f"OK\t{score:.6f}\t{path}")
        except Exception as exc:
            print(f"ERR\t{exc}\t{path}")
        sys.stdout.flush()


if __name__ == "__main__":
    main()
