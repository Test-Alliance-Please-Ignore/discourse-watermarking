/* eslint-disable no-bitwise -- this module implements the watermark bit codec */

// Pure helpers shared by the watermark initializer and its tests.
//
// The payload format and the zero-width codec must stay in sync with
// lib/discourse_watermarking/payload.rb and
// lib/discourse_watermarking/zero_width.rb.

export const CELLS_PER_ROW = 8;

// 00 => ZWSP, 01 => ZWNJ, 10 => ZWJ, 11 => WORD JOINER
export const ZERO_WIDTH_ALPHABET = ["\u200B", "\u200C", "\u200D", "\u2060"];
export const ZERO_WIDTH_MARKER = "\u200D\u200C\u200D\u2060";

const EXCLUDED_ROUTE_PREFIXES = [
  "admin",
  "login",
  "signup",
  "invites.",
  "wizard",
  "account-created",
  "activate-account",
  "password-reset",
];

const EXCLUDED_URL_PREFIXES = [
  "/admin",
  "/login",
  "/signup",
  "/session",
  "/invites/",
  "/wizard",
  "/u/password-reset",
  "/u/activate-account",
  "/u/confirm-",
  "/u/account-created",
];

export function hexToBits(hex) {
  const bits = [];
  for (const nibble of hex.toLowerCase()) {
    const value = parseInt(nibble, 16);
    if (isNaN(value)) {
      return null;
    }
    for (let i = 3; i >= 0; i--) {
      bits.push((value >> i) & 1);
    }
  }
  return bits;
}

// Builds the 8x8 mask tile for a 64-bit tile payload. Each 1-bit becomes a
// large, rounded, slightly blurred block: a low-spatial-frequency mark that
// survives screenshot downscaling and JPEG recompression far better than
// fine dots, at the cost of needing a bigger crop to recover — which the
// periodic tiling compensates for.
export function buildTileSvg(hex) {
  const bits = hexToBits(hex);
  if (!bits || bits.length !== CELLS_PER_ROW * CELLS_PER_ROW) {
    return null;
  }

  let rects = "";
  bits.forEach((bit, index) => {
    if (!bit) {
      return;
    }
    const x = index % CELLS_PER_ROW;
    const y = Math.floor(index / CELLS_PER_ROW);
    rects += `<rect x="${x + 0.05}" y="${y + 0.05}" width="0.9" height="0.9" rx="0.25"/>`;
  });

  return (
    `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${CELLS_PER_ROW} ${CELLS_PER_ROW}">` +
    `<filter id="s"><feGaussianBlur stdDeviation="0.07"/></filter>` +
    `<g fill="#fff" filter="url(#s)">${rects}</g>` +
    `</svg>`
  );
}

export function buildMaskUrl(hex) {
  const svg = buildTileSvg(hex);
  if (!svg) {
    return null;
  }
  return `url("data:image/svg+xml,${encodeURIComponent(svg)}")`;
}

export function encodeZeroWidth(hex) {
  const bits = hexToBits(hex);
  if (!bits || bits.length % 2 !== 0) {
    return null;
  }
  let out = ZERO_WIDTH_MARKER;
  for (let i = 0; i < bits.length; i += 2) {
    out += ZERO_WIDTH_ALPHABET[(bits[i] << 1) | bits[i + 1]];
  }
  return out;
}

export function isExcludedRoute(routeName, url) {
  if (routeName) {
    for (const prefix of EXCLUDED_ROUTE_PREFIXES) {
      if (routeName === prefix || routeName.startsWith(prefix)) {
        return true;
      }
    }
  }
  if (url) {
    const path = url.split("?")[0];
    for (const prefix of EXCLUDED_URL_PREFIXES) {
      if (path === prefix || path.startsWith(prefix)) {
        return true;
      }
    }
  }
  return false;
}

// Never fingerprint text copied from code, preformatted blocks, or editable
// fields: invisible characters would corrupt pasted code and drafts.
export function selectionAllowsFingerprint(selection) {
  if (!selection || selection.isCollapsed) {
    return false;
  }

  for (const node of [selection.anchorNode, selection.focusNode]) {
    if (!node) {
      return false;
    }
    const element = node.nodeType === Node.ELEMENT_NODE ? node : node.parentElement;
    if (!element) {
      return false;
    }
    if (element.closest("pre, code, kbd, samp, input, textarea, [contenteditable='true']")) {
      return false;
    }
  }
  return true;
}
