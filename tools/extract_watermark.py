#!/usr/bin/env python3
"""Recover a discourse-watermarking payload from a screenshot.

The watermark is a periodic 8x8 grid of large low-contrast blocks tiled
across the viewport. Because the pattern repeats with a fixed period, every
tile in the screenshot is a noisy observation of the same 64-bit payload:
folding the image at the tile period and averaging cancels the page content
(text, images) and amplifies the watermark.

Since plugin version 0.2 the overlay difference-blends a dark blue, which
subtracts a constant amount from the blue channel only, so the mark lives
almost entirely in the blue-vs-gray chroma plane (B - (R+G)/2) with the
same amplitude on every theme. Forum content is overwhelmingly neutral
gray — text, borders, scrollbars vanish in that plane — which is why it is
analyzed first. The luminance plane is still swept afterwards so
screenshots made under the old gray overlay keep decoding.

Usage:
    python3 tools/extract_watermark.py screenshot.png [--cell 32] [--min-scale 0.5] [--max-scale 4]
    python3 tools/extract_watermark.py leak1.png leak2.png ...   # stack (see below)

    --cell       cell size in CSS px configured in
                 user_fingerprint_visual_density (default 32)
    --min-scale / --max-scale
                 range of device-pixel-ratio / zoom / resize factors to try
    --plane      chroma | luma | auto (default auto: both, merged)
    --stack      force multi-screenshot stacking mode (auto-enabled when more
                 than one image is given)

The tool prints candidate 16-character hex payloads (best first). Paste the
whole list into the admin decoder at
/admin/plugins/discourse-watermarking/watermarking; the cryptographic
integrity tag identifies the correct candidate, tolerating a few flipped
bits.

Stacking mode is for hard leaks — short crops, a big saturated image over the
content, at the lowest opacity — where a single screenshot will not decode.
Give it two or more screenshots FROM THE SAME USER (they all carry the same
payload). It pools noisy 8x8 reads from every image, locks each to the
canonical orientation using the known sync byte and version nibble as a
template (rather than reading those bits from noise), averages only the reads
that lock cleanly, and enumerates the few genuinely uncertain payload cells.
It reports a sync-lock quality: ~1.0 means the watermark was found and
aligned; below ~0.5 means no recoverable watermark is present.

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

# Known-constant cells of a v1 tile, used by stacking mode to lock each noisy
# read to the canonical orientation and roll. Row 0 is the sync byte 0xC5;
# row 1 is byte 1 = (VERSION << 4) = 0x10 (version nibble 1, reserved nibble
# 0). Matching against these 16 known bits is far more reliable than reading
# the sync out of a near-noise-floor signal.
KNOWN_TILE = np.full((GRID, GRID), np.nan)
KNOWN_TILE[0] = [(SYNC_BYTE >> i) & 1 for i in range(7, -1, -1)]
KNOWN_TILE[1] = [(((PAYLOAD_VERSION << 4) & 0xFF) >> i) & 1 for i in range(7, -1, -1)]
KNOWN_MASK = ~np.isnan(KNOWN_TILE)
KNOWN_SIGN = np.where(KNOWN_MASK, KNOWN_TILE * 2 - 1, 0.0)


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
    """The 2D planes to sweep, most promising first, each paired with a gate
    mask of pixels that are allowed to contribute to the fold.

    chroma (B - (R+G)/2) isolates the blue overlay and cancels neutral-gray
    page content; luma covers screenshots from the pre-0.2 gray overlay.

    The chroma plane is additionally gated to near-neutral pixels: a
    saturated embedded image (an avatar, a meme, a rainbow onebox) carries
    strong chroma of its own that would otherwise swamp the 1-2 level
    watermark it sits under. Rejecting colored pixels keeps only the page
    background and text — exactly where the mark lives — which is decisive
    on short, image-heavy screenshots."""
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    planes = []
    if plane in ("auto", "chroma"):
        neutral = (np.abs(r - g) < 6) & (np.abs(np.maximum(r, g) - b) < 10)
        planes.append((b - 0.5 * (r + g), neutral))
    if plane in ("auto", "luma"):
        planes.append((rgb @ np.array([0.299, 0.587, 0.114]), None))
    return planes


def folded_tile(img, keep, period):
    """Fold at one period and strip the residual page background with a
    wrap-around low-pass, keeping only cell-scale structure. Returns
    (tile, repetitions, spread); spread measures how much periodic
    structure survived the fold and peaks sharply at the true period."""
    tile, repetitions = fold(img, period, keep)
    if tile is None or repetitions < 0.9:
        return None, 0, 0.0
    tile = tile - box_blur(tile, max(2, period // 6), mode="wrap")
    spread = np.percentile(tile, 95) - np.percentile(tile, 5)
    return tile, repetitions, spread


def decode_tile(tile, period, repetitions, found):
    step = max(1, period // (GRID * 8))
    for off_y, off_x in itertools.product(range(0, period // GRID, step), repeat=2):
        means = cell_means(tile, off_y, off_x)
        for gap, hex_payload in candidates_from_grid(means):
            weighted = gap * np.sqrt(repetitions)
            if hex_payload not in found or found[hex_payload] < weighted:
                found[hex_payload] = weighted


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
    # The coarse sweep advances base_period/8 pixels at a time, but real
    # screenshots come from fractional display scales and browser zooms
    # (e.g. 1.09 → period 279), where folding at the nearest coarse period
    # smears the tile into corrupt reads. After the coarse pass, fine-scan
    # ±half a coarse step around the strongest fold responses in 1px steps
    # and decode at the refined peak as well.
    fine_halfwidth = max(2, base_period // 16)

    for img, gate in analysis_planes(rgb, plane):
        for mask_bg_radius, mask_erode_radius in presets:
            keep = content_mask(img, mask_bg_radius, erode_radius=mask_erode_radius)
            if gate is not None:
                keep = keep & gate

            spreads = {}
            for period in scales:
                if period < GRID * 4:
                    continue
                tile, repetitions, spread = folded_tile(img, keep, period)
                if tile is None:
                    continue
                spreads[period] = spread
                decode_tile(tile, period, repetitions, found)

            for coarse_peak in sorted(spreads, key=lambda p: -spreads[p])[:2]:
                fine = dict.fromkeys(
                    range(
                        max(GRID * 4, coarse_peak - fine_halfwidth),
                        coarse_peak + fine_halfwidth + 1,
                    )
                )
                for period in fine:
                    if period in spreads:
                        fine[period] = spreads[period]
                        continue
                    _, _, fine[period] = folded_tile(img, keep, period)
                peak = max(fine, key=lambda p: fine[p] or 0.0)
                for period in (peak - 1, peak, peak + 1):
                    if period in spreads or period < GRID * 4:
                        continue
                    tile, repetitions, _ = folded_tile(img, keep, period)
                    if tile is not None:
                        decode_tile(tile, period, repetitions, found)

    return sorted(found.items(), key=lambda item: -item[1])


def soft_reads(rgb, cell, min_scale, max_scale, presets):
    """Collect many normalized 8x8 soft reads (real-valued cell grids) of one
    image on the neutral-gated chroma plane. Unlike extract(), which commits
    each fold to hard 0/1 bits immediately, stacking needs the soft values so
    it can average across reads and images before thresholding."""
    grids = []
    base_period = cell * GRID
    coarse_scales = np.unique(
        np.round(np.arange(min_scale, max_scale + 1e-9, 0.125) * base_period).astype(int)
    )
    # Around the coarse peak, the exact tile period must be found to the pixel:
    # folding even one or two pixels off the true period smears the tile and
    # rotates the recovered payload, which stacking cannot average out. So
    # after the coarse sweep locates the peak (within one coarse step), sweep
    # every integer period across a band wide enough to bracket it, and pool
    # reads from the strongest few. A discrete "top-N coarse periods" sample
    # is not enough — it misses the true period and locks onto a wrong roll.
    band = base_period // 4

    # Chroma only: the stack technique locks onto the blue-channel mark, and
    # the neutral gate paired with the chroma plane is what rejects the
    # saturated image that makes these leaks hard in the first place.
    for img, gate in analysis_planes(rgb, "chroma"):
        for mask_bg_radius, mask_erode_radius in presets:
            keep = content_mask(img, mask_bg_radius, erode_radius=mask_erode_radius)
            if gate is not None:
                keep = keep & gate

            coarse_spread = {}
            for period in coarse_scales:
                if period < GRID * 4:
                    continue
                tile, repetitions, spread = folded_tile(img, keep, period)
                if tile is not None:
                    coarse_spread[period] = spread
            if not coarse_spread:
                continue
            peak = max(coarse_spread, key=coarse_spread.get)

            dense = {}
            for period in range(max(GRID * 4, peak - band), peak + band + 1):
                tile, repetitions, spread = folded_tile(img, keep, period)
                if tile is not None:
                    dense[period] = (spread, tile)

            for period in sorted(dense, key=lambda p: -dense[p][0])[:3]:
                _, tile = dense[period]
                step = max(1, period // (GRID * 8))
                for off_y, off_x in itertools.product(range(0, period // GRID, step), repeat=2):
                    means = cell_means(tile, off_y, off_x)
                    means = means - means.mean()
                    scale = means.std()
                    if scale > 1e-9:
                        grids.append(means / scale)
    return grids


def lock_to_sync(grid):
    """Return (correlation, canonical_grid): the orientation, mirror, polarity,
    and cyclic roll of `grid` that best matches the known sync+version
    template, and how well it matched (1.0 = perfect)."""
    best_corr = -np.inf
    best_grid = None
    for k in range(4):
        rotated = np.rot90(grid, k)
        for oriented in (rotated, np.fliplr(rotated)):
            for polarity in (1.0, -1.0):
                signed = polarity * oriented
                for roll_y in range(GRID):
                    for roll_x in range(GRID):
                        rolled = np.roll(np.roll(signed, roll_y, axis=0), roll_x, axis=1)
                        corr = (rolled * KNOWN_SIGN)[KNOWN_MASK].mean()
                        if corr > best_corr:
                            best_corr = corr
                            best_grid = rolled
    return best_corr, best_grid


def stack_extract(
    paths,
    cell,
    min_scale,
    max_scale,
    bg_radius=None,
    erode_radius=None,
    keep_fraction=0.10,
    keep_floor=24,
    max_uncertain=10,
    max_candidates=48,
):
    """Recover one payload shared by several same-user screenshots.

    Pools soft reads from every image, locks each to the canonical frame via
    the sync template, averages only the cleanest-locking reads, then reads
    the payload and enumerates flips of the least-confident cells. Returns
    (ranked_hex_candidates, sync_quality).

    Only the top `keep_fraction` of reads by sync-lock quality are averaged:
    the reads that lock cleanest carry the payload, and admitting the rest
    only adds noise (empirically each 5% loosening costs ~1 bit of accuracy).
    `keep_floor` guarantees a usable average when few reads are available."""
    if bg_radius is not None or erode_radius is not None:
        presets = [(bg_radius or 12, 3 if erode_radius is None else erode_radius)]
    else:
        presets = [(12, 3), (6, 1), (18, 4)]

    grids = []
    for path in paths:
        rgb = np.asarray(Image.open(path).convert("RGB"), dtype=np.float64)
        grids.extend(soft_reads(rgb, cell, min_scale, max_scale, presets))
    if not grids:
        return [], 0.0

    locked = sorted((lock_to_sync(grid) for grid in grids), key=lambda cg: -cg[0])
    keep_count = min(len(locked), max(keep_floor, round(len(locked) * keep_fraction)))
    kept = [grid for _, grid in locked[:keep_count]]
    average = np.mean(kept, axis=0)
    sync_quality = float((average * KNOWN_SIGN)[KNOWN_MASK].mean())

    unknown = [(y, x) for y in range(GRID) for x in range(GRID) if not KNOWN_MASK[y, x]]
    order = sorted(range(len(unknown)), key=lambda i: abs(average[unknown[i]]))
    flip_cells = [unknown[i] for i in order[: min(max_uncertain, len(unknown))]]

    base = KNOWN_TILE.copy()
    for cell_yx in unknown:
        base[cell_yx] = 1.0 if average[cell_yx] > 0 else 0.0

    candidates = []
    for combo in itertools.product((0, 1), repeat=len(flip_cells)):
        grid = base.copy()
        cost = 0.0
        for bit, cell_yx in zip(combo, flip_cells):
            grid[cell_yx] = bit
            if bit != (1 if average[cell_yx] > 0 else 0):
                cost += abs(average[cell_yx])
        candidates.append((cost, bits_to_hex(grid.flatten().astype(int))))

    candidates.sort(key=lambda item: item[0])
    seen = set()
    ranked = []
    for _, hex_payload in candidates:
        if hex_payload not in seen:
            seen.add(hex_payload)
            ranked.append(hex_payload)
        if len(ranked) >= max_candidates:
            break
    return ranked, sync_quality


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("images", nargs="+", help="screenshot file(s) (PNG/JPEG); two or more enables stacking")
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
    parser.add_argument(
        "--stack",
        action="store_true",
        help="force multi-screenshot stacking (auto-enabled for 2+ images)",
    )
    args = parser.parse_args()

    if args.stack or len(args.images) > 1:
        ranked, sync_quality = stack_extract(
            args.images, args.cell, args.min_scale, args.max_scale, args.bg_radius, args.erode
        )
        if not ranked:
            print("No candidate payload found. Try more or larger screenshots of")
            print("the same user, or a higher user_fingerprint_visual_opacity.")
            sys.exit(1)

        print(
            f"Stacked {len(args.images)} screenshot(s); sync-lock quality {sync_quality:.2f} "
            "(1.00 = perfect lock, below 0.50 likely means no recoverable watermark)."
        )
        print("Candidate payloads (paste the WHOLE list into the admin decoder, best first):")
        for hex_payload in ranked[: max(args.top, 32)]:
            print(f"  {hex_payload}")
        return

    results = extract(
        args.images[0], args.cell, args.min_scale, args.max_scale, args.bg_radius, args.erode, args.plane
    )

    if not results:
        print("No candidate payload found. Try adjusting --cell to match the")
        print("user_fingerprint_visual_density setting, widening the scale range,")
        print("or using a larger / less compressed screenshot region. For a hard")
        print("leak, pass several same-user screenshots to enable --stack.")
        sys.exit(1)

    print("Candidate payloads (paste into the admin decoder, best first):")
    for hex_payload, score in results[: args.top]:
        print(f"  {hex_payload}    (score {score:.2f})")


if __name__ == "__main__":
    main()
