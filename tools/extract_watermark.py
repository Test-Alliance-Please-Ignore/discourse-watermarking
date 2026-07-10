#!/usr/bin/env python3
"""Recover a discourse-watermarking payload from a screenshot.

The watermark is a periodic 8x8 grid of large low-contrast blocks tiled
across the viewport. Because the pattern repeats with a fixed period, every
tile in the screenshot is a noisy observation of the same 64-bit payload:
folding the image at the tile period and averaging cancels the page content
(text, images) and amplifies the watermark.

Since plugin version 0.2 the overlay is pure blue, so the mark lives almost
entirely in the blue-vs-gray chroma plane (B - (R+G)/2). Forum content is
overwhelmingly neutral gray — text, borders, scrollbars vanish in that
plane — which is why it is analyzed first. The luminance plane is still
swept afterwards so screenshots made under the old gray overlay keep
decoding.

Usage:
    python3 tools/extract_watermark.py screenshot.png [--cell 32] [--min-scale 0.5] [--max-scale 4]

    --cell       cell size in CSS px configured in
                 user_fingerprint_visual_density (default 32)
    --min-scale / --max-scale
                 range of device-pixel-ratio / zoom / resize factors to try
    --plane      chroma | luma | auto (default auto: both, merged)

The tool prints candidate 16-character hex payloads (best first). Paste the
whole list into the admin decoder at
/admin/plugins/discourse-watermarking/watermarking; the cryptographic
integrity tag identifies the correct candidate, tolerating a few flipped
bits.

Requires: pillow, numpy  (pip install pillow numpy)
"""

import argparse
import itertools
import sys

try:
    import numpy as np
    from PIL import Image
except ImportError:
    sys.exit("This tool requires pillow and numpy: pip install pillow numpy")

SYNC_BYTE = 0xC5
PAYLOAD_VERSION = 1
GRID = 8


def box_blur_1d(img, radius, axis, mode="reflect"):
    kernel = 2 * radius + 1
    pad = [(0, 0), (0, 0)]
    pad[axis] = (radius, radius)
    padded = np.pad(img, pad, mode=mode)
    cumsum = np.insert(np.cumsum(padded, axis=axis, dtype=np.float64), 0, 0.0, axis=axis)
    if axis == 0:
        return (cumsum[kernel:, :] - cumsum[:-kernel, :]) / kernel
    return (cumsum[:, kernel:] - cumsum[:, :-kernel]) / kernel


def box_blur(img, radius, mode="reflect"):
    """Approximate Gaussian blur with three box blurs (no scipy needed)."""
    for _ in range(3):
        img = box_blur_1d(box_blur_1d(img, radius, 0, mode), radius, 1, mode)
    return img


def content_mask(img, bg_radius, k=2.0, erode_radius=3):
    """Keep only pixels close to the local page background. Text strokes,
    images, and UI chrome are orders of magnitude stronger than the watermark
    and would otherwise dominate the fold. The mask is eroded so the blurred
    halo around rejected content is dropped as well."""
    background = box_blur(img.copy(), bg_radius)
    residual = img - background
    mad = np.median(np.abs(residual - np.median(residual))) * 1.4826
    keep = np.abs(residual) < max(k * mad, 6.0)
    if erode_radius:
        keep = box_blur(keep.astype(np.float64), erode_radius) > 0.999
    return keep


def fold(img, period, keep):
    """Average every non-content pixel into its (y % period, x % period) bin.
    Partial tiles contribute too, which matters on small screenshots."""
    h, w = img.shape
    if h < period and w < period:
        return None, 0

    ys = np.arange(h) % period
    xs = np.arange(w) % period
    flat_idx = (ys[:, None] * period + xs[None, :]).ravel()
    kept = keep.ravel()

    counts = np.bincount(flat_idx[kept], minlength=period * period)
    sums = np.bincount(flat_idx[kept], weights=img.ravel()[kept], minlength=period * period)
    with np.errstate(invalid="ignore"):
        folded = sums / counts
    folded = np.where(counts > 0, folded, np.nanmean(folded))

    repetitions = kept.mean() * (h / period) * (w / period)
    return folded.reshape(period, period), repetitions


def cell_means(tile, offset_y, offset_x):
    """8x8 matrix of mean values sampled over each cell interior."""
    period = tile.shape[0]
    cell = period / GRID
    means = np.zeros((GRID, GRID))
    half = max(1, int(cell * 0.38))
    for y in range(GRID):
        for x in range(GRID):
            cy = int((y + 0.5) * cell + offset_y) % period
            cx = int((x + 0.5) * cell + offset_x) % period
            ys = [(cy + dy) % period for dy in range(-half, half + 1)]
            xs = [(cx + dx) % period for dx in range(-half, half + 1)]
            means[y, x] = tile[np.ix_(ys, xs)].mean()
    return means


def orientations(matrix):
    """All 8 rotations/mirrorings of the grid."""
    for k in range(4):
        rotated = np.rot90(matrix, k)
        yield rotated
        yield np.fliplr(rotated)


def bits_to_hex(bits):
    value = 0
    for bit in bits:
        value = (value << 1) | int(bit)
    return f"{value:016x}"


def two_means_split(values):
    """Split 64 cell values into two clusters; returns (bits, gap).

    The gap is the absolute distance between the cluster means. Scoring by
    the gap (not a gap/spread ratio) matters: folds at a wrong period
    produce nearly uniform tiles whose tiny accidental splits have huge
    ratios but negligible gaps, and they would otherwise outrank the real
    payload."""
    lo, hi = values.min(), values.max()
    if hi - lo < 1e-12:
        return None, 0.0
    threshold = (lo + hi) / 2
    for _ in range(16):
        low, high = values[values <= threshold], values[values > threshold]
        if len(low) == 0 or len(high) == 0:
            return None, 0.0
        new_threshold = (low.mean() + high.mean()) / 2
        if abs(new_threshold - threshold) < 1e-9:
            break
        threshold = new_threshold
    low, high = values[values <= threshold], values[values > threshold]
    # Real payloads are HMAC output and therefore statistically balanced;
    # a lopsided split is a content artifact, not a watermark.
    if len(low) < 12 or len(high) < 12:
        return None, 0.0
    return (values > threshold).astype(int), high.mean() - low.mean()


def candidates_from_grid(means):
    """Cluster the 8x8 cell means into 0/1 bits and return payload candidates
    whose sync row and version nibble match. Because the pattern is periodic,
    a crop can start anywhere inside a tile, so every cyclic shift of the
    recovered grid is a valid reading — try them all, in every orientation
    and both polarities."""
    results = []
    for grid in orientations(means):
        for polarity in (1, -1):
            bits, gap = two_means_split(grid.flatten() * polarity)
            if bits is None:
                continue
            bit_grid = bits.reshape(GRID, GRID)
            matches = []
            for roll_y in range(GRID):
                for roll_x in range(GRID):
                    rolled = np.roll(np.roll(bit_grid, roll_y, axis=0), roll_x, axis=1)
                    sync = int("".join(map(str, rolled[0])), 2)
                    version = int("".join(map(str, rolled[1][:4])), 2)
                    if sync == SYNC_BYTE and version == PAYLOAD_VERSION:
                        matches.append(bits_to_hex(rolled.flatten()))
            # A reading that matches the sync pattern at many shifts is a
            # periodic content artifact, not a payload.
            if 0 < len(matches) <= 2:
                results.extend((gap, match) for match in matches)
    return results


def analysis_planes(rgb, plane):
    """The 2D planes to sweep, most promising first.

    chroma (B - (R+G)/2) isolates the blue overlay and cancels neutral-gray
    page content; luma covers screenshots from the pre-0.2 gray overlay."""
    planes = []
    if plane in ("auto", "chroma"):
        planes.append(rgb[..., 2] - 0.5 * (rgb[..., 0] + rgb[..., 1]))
    if plane in ("auto", "luma"):
        planes.append(rgb @ np.array([0.299, 0.587, 0.114]))
    return planes


def extract(path, cell, min_scale, max_scale, bg_radius=None, erode_radius=None, plane="auto"):
    rgb = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64)

    # Mask parameters depend on the effective resolution of the screenshot
    # (full-DPR screenshots vs. downscaled re-shares), so sweep two presets
    # unless the caller pinned them.
    if bg_radius is not None or erode_radius is not None:
        presets = [(bg_radius or 12, 3 if erode_radius is None else erode_radius)]
    else:
        presets = [(12, 3), (6, 1)]

    found = {}
    base_period = cell * GRID
    scales = np.unique(
        np.round(np.arange(min_scale, max_scale + 1e-9, 0.125) * base_period).astype(int)
    )

    for img in analysis_planes(rgb, plane):
        for mask_bg_radius, mask_erode_radius in presets:
            keep = content_mask(img, mask_bg_radius, erode_radius=mask_erode_radius)

            for period in scales:
                if period < GRID * 4:
                    continue
                tile, repetitions = fold(img, period, keep)
                if tile is None or repetitions < 0.9:
                    continue

                # The folded tile is periodic, so remove the residual page
                # background with a wrap-around low-pass and keep only
                # cell-scale structure.
                tile = tile - box_blur(tile, max(2, period // 6), mode="wrap")

                step = max(1, period // (GRID * 8))
                for off_y, off_x in itertools.product(range(0, period // GRID, step), repeat=2):
                    means = cell_means(tile, off_y, off_x)
                    for gap, hex_payload in candidates_from_grid(means):
                        weighted = gap * np.sqrt(repetitions)
                        if hex_payload not in found or found[hex_payload] < weighted:
                            found[hex_payload] = weighted

    return sorted(found.items(), key=lambda item: -item[1])


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("image", help="screenshot file (PNG/JPEG)")
    parser.add_argument("--cell", type=int, default=32, help="configured cell size in CSS px (default 32)")
    parser.add_argument("--min-scale", type=float, default=0.5)
    parser.add_argument("--max-scale", type=float, default=4.0)
    parser.add_argument("--bg-radius", type=int, default=None, help="background estimation blur radius in px (default: sweep 12 and 6)")
    parser.add_argument("--erode", type=int, default=None, help="content mask erosion radius in px (default: sweep 3 and 1)")
    parser.add_argument("--top", type=int, default=12, help="number of candidates to print")
    parser.add_argument(
        "--plane",
        choices=("auto", "chroma", "luma"),
        default="auto",
        help="color plane to analyze (default: chroma then luma, merged)",
    )
    args = parser.parse_args()

    results = extract(
        args.image, args.cell, args.min_scale, args.max_scale, args.bg_radius, args.erode, args.plane
    )

    if not results:
        print("No candidate payload found. Try adjusting --cell to match the")
        print("user_fingerprint_visual_density setting, widening the scale range,")
        print("or using a larger / less compressed screenshot region.")
        sys.exit(1)

    print("Candidate payloads (paste into the admin decoder, best first):")
    for hex_payload, score in results[: args.top]:
        print(f"  {hex_payload}    (score {score:.2f})")


if __name__ == "__main__":
    main()
