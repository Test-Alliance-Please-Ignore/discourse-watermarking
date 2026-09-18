**Dark Reader compatibility and overlay discoverability audit — 18 September 2026**

Audited revision: `9614803771b2a290529c144b48989bf125028273`.
This report records the original findings and the follow-up diagnosis below.
The first fix protects screen/print paint, removes the descriptive overlay
ID/class, and adds
[browser regression coverage](../../test/browser/watermark_rendering.py).
The historical reproduction below reads the audited Git revision so its
measurements remain reproducible after those fixes.

Verification of the first fix passed with the pinned Dynamic API engine in both
Firefox 153.0 and Chromium 151.0.7922.34: native and themed screenshots retained
the `[0, 0, 2]` signal, print retained its blue chroma signal, and navigation,
print restoration, teardown/reinitialization, and exclusions passed. The test
payload was recovered from PNG, JPEG quality 70, and print captures in both
browsers, plus a rasterized Chromium PDF. JavaScript, stylesheet, and Ruby lint
checks passed. The Discourse QUnit runner could not boot its local Rails server
because Redis was unavailable. That verification did not include a matching
element inversion rule and therefore missed the remaining reported failure.
See the [README](../../README.md#testing) for the current regression commands.

**Follow-up: an element filter bypassed the colour-only protection.** The
reported computed styles show `background-color: rgb(0, 0, 1)`, inline
important priority, difference blending, and opacity 1. The document and body
filters are `none`, but the overlay itself has
`filter: invert(1) hue-rotate(180deg) brightness(0.75) contrast(0.9)`.
This transforms its painted pixels after background-colour computation, so
checking or protecting that colour alone cannot fix this case.

Injecting that exact filter as an important stylesheet rule into the browser
regression reproduced the failure before the follow-up fix: the maximum
red/green/blue screenshot difference reached `137 / 133 / 131` instead of
being bounded by the configured two blue levels. The follow-up sets
`filter: none !important` inline when creating the overlay, before attaching
it. It applies to the overlay during both screen and print rendering; Dark
Reader continues theming the rest of the page.

With that protection, Firefox 153.0 and Chromium 151.0.7922.34 pass pixel,
computed-filter, navigation, remounting, print, and exclusion checks while the
inversion rule remains active. The synthetic payload is recovered from PNG
and JPEG quality-70 captures at settings 4 and 8 (one and two blue levels),
print captures in both browsers, and a rasterized Chromium PDF. The acceptance
test now includes the reported filter as well as the background-colour
override. Full Discourse QUnit execution remains limited by the unavailable
local Redis service.

An additional check installed the signed Mozilla Dark Reader 4.9.131 add-on in
Firefox 155.0.1 against the local synthetic renderer fixture. A developer
`INVERT` rule targeting `.d-view-layer`, Dynamic mode, brightness 75, and
contrast 100 produced the exact reported computed filter (the extension's
inversion rule reduces contrast to 90%). Temporarily removing only the inline
filter protection reproduced maximum pixel differences of `148 / 144 / 145`;
restoring it returned them to `0 / 0 / 2`, with Dynamic mode still active.
This verifies the installed extension's inversion path under a controlled
matching rule. It does not establish which selector on the reported forum
triggered that rule, nor replace verification on that live forum.

The remainder of this report preserves the original audit and its evidence.

**The reported visual problem is reproducible.** Dark Reader brightens the
overlay's near-black blue paint because it interprets a CSS-masked background
as foreground artwork. The overlay then blends that bright colour over the
page at full opacity. The best first fix is to preserve the exact inline paint
colour, preserve the separate print treatment, and remove the descriptive DOM
identifier. A new rendering system is not necessary to fix the reproduced case.

| Priority | Finding | Recommended action |
|---|---|---|
| P1 | Dark Reader amplifies the visual pattern dramatically | Protect the exact screen paint colour and verify the resulting pixels |
| P1, part of the same fix | An inline `!important` repair defeats the current print colour override | Update print colour handling in the same change |
| P2 | Both the overlay ID and class explicitly identify watermarking | Remove the ID if unnecessary; use a neutral, namespaced styling class |
| P2 | Existing tests inspect presence and authored styles, missing this failure | Add computed-style, pixel-difference, and extraction checks with Dark Reader |
| P3 | Documentation overstates invisibility and describes outdated rendering behaviour | Correct the rendering explanation and verification instructions |

**The reproduction uses the actual plugin renderer.** The isolated browser
harness loads the repository's initializer, SVG helpers, and stylesheet,
substituting only Discourse's service lookup and page-change API. It supplies a
synthetic payload, density `32`, and the default amplitude setting `8`, which
maps to two blue-channel levels. The viewport is 1024 × 768 at DPR 1 over a
plain background, with no posts, accounts, or private data.

Tests used the official Dark Reader **4.9.131 API build**, Dynamic mode with
brightness/contrast 100 and sepia 0, in Chromium **151.0.7922.34** and Firefox
**153.0**. The API is an upstream-supported way to run its theme engine.
These are engine-level reproductions, **not a test of an installed Firefox
extension on a running Discourse site**. The actual reported browser version,
extension configuration, and forum theme were not supplied. The Mozilla listing
identified 4.9.131 at audit time. See the
[Mozilla listing](https://addons.mozilla.org/en-US/firefox/addon/darkreader/) and
[upstream API instructions](https://github.com/darkreader/darkreader#using-dark-reader-on-a-website).

| Measurement | Dark Reader off | Dark Reader on | On, with proposed inline protection |
|---|---|---|---|
| Computed overlay background | `rgb(0, 0, 2)` | `rgb(231, 229, 226)` | `rgb(0, 0, 2)` |
| Computed blend mode | `difference` | `difference` | `difference` |
| Computed element opacity | `1` | `1` | `1` |
| Maximum screenshot difference, R/G/B | `0 / 0 / 2` | `183 / 177 / 172` | `0 / 0 / 2` |

Both engines produced those values. Pixel differences compare the same themed
page with the overlay visible and hidden; they do not confuse the whole-page
theme change with the watermark's contribution. Screenshots show the
[broken rendering](dark-reader-2026-09-18/firefox-current-after.png) and
[protected rendering](dark-reader-2026-09-18/firefox-inline-important-after.png).
The supplied [browser harness](dark-reader-2026-09-18/reproduce.py) reports:

```text
FAIL: Dark Reader amplified the overlay beyond the configured 2 levels
```

**The mask-aware colour conversion is the cause of this reproduction.**
The initializer assigns a normal inline `backgroundColor` and an SVG
`maskImage` in
[renderOverlay](../../assets/javascripts/discourse/initializers/discourse-watermarking.js)
(lines 74–107). The
[screen stylesheet](../../assets/stylesheets/common/discourse-watermarking.scss)
(lines 19–32) applies `mix-blend-mode: difference` with no element-opacity
attenuation. This is intentional: the small numeric colour value carries the
signal.

Dark Reader's `getColorModifier` chooses foreground conversion for a background
declaration accompanied by a non-gradient mask. Its inline-style processor
then supplies a generated colour through `--darkreader-inline-bgcolor` and an
`!important` stylesheet rule. The original `element.style.backgroundColor`
still reads `rgb(0, 0, 2)` while the computed colour is nearly white. See
[upstream colour conversion](https://github.com/darkreader/darkreader/blob/main/src/inject/dynamic-theme/modify-css.ts)
and [inline overrides](https://github.com/darkreader/darkreader/blob/main/src/inject/dynamic-theme/inline-style.ts).
The pinned API file and checksum used for this audit are recorded below.

The controlled experiments separate the possible causes:

- Removing only the mask stopped the brightening under the tested defaults,
  confirming that masked-foreground treatment matters. This also removes the
  encoded pattern and is not a fix.
- Keeping the mask and protecting only the inline background preserved the
  two-level signal in both engines. Blend mode and mask remained present.
- Passing `ignoreInlineStyle` through Dark Reader's API also preserved the
  signal. Adding `data-darkreader-ignore` to the overlay did **not**.
- Multiplying the existing low-amplitude paint by a second low element opacity
  weakened the signal. In Firefox it disappeared entirely before Dark Reader
  was enabled. This is not an equivalent replacement for protecting the colour.

**Implement the repair in this order.**

1. **Protect the numeric paint value before attaching the overlay.** Replace
   the ordinary assignment in `renderOverlay` with the equivalent of:

   ```js
   overlay.style.setProperty(
     "background-color",
     `rgb(0 0 ${amplitude})`,
     "important"
   );
   ```

   Inline author `!important` wins over Dark Reader's generated author
   stylesheet rule in the tested engines. Keep the existing payload, SVG,
   amplitude calculation, density, and blending contract. The prototype also
   checks extension-engine toggles, changed brightness/contrast/sepia, and
   recreation while the theme engine is active. This protects this particular
   colour declaration; it is not immunity from user styles or other rendering
   transformations.

2. **Preserve print colour explicitly.** The existing `@media print` rule
   changes the paint to `#00f !important`, sets normal blending, and applies
   opacity `0.012`. An inline important near-black colour outranks that rule.
   In print-media emulation the proposed one-line screen fix therefore produces
   a faint gray signal instead of the intended blue signal. It may still carry
   a luminance watermark, but its original chroma contract is lost.

   A small implementation can centralize paint assignment and switch the inline
   important colour to `rgb(0 0 255)` for print, restoring the configured screen
   value afterward. Account for `beforeprint`/`afterprint`, print-media changes,
   initial media state, cancellation, and initializer teardown. A separately
   styled print surface is another option if it simplifies browser behaviour.
   Validate actual print preview and PDF output; this audit only emulated print
   media and did not validate those lifecycle hooks or PDF extraction. Ship the
   screen and print handling together.

3. **Remove the obvious DOM label with a limited naming change.** The constant
   on initializer line 9 and the assignment on line 83 produce
   `id="discourse-watermark-overlay"` and
   `class="discourse-watermark-overlay"`. Retain the node in the initializer's
   closure, use its reference for cleanup and duplicate prevention, and omit
   the ID if nothing else needs it. Give the remaining style hook a neutral,
   namespaced name such as `d-view-layer`. Update both screen/print selectors,
   acceptance helpers, system specs, and any documented selectors together.
   Keep `aria-hidden`, pointer transparency, selection behaviour, scoping, and
   teardown intact. Avoid replacing the removed label with an equally explicit
   `data-watermark` attribute or test hook in production markup.

   This removes casual identification through the element name. It cannot make
   client-side watermarking undiscoverable: the full-screen layer, mask data,
   and client code remain inspectable. Additional explicit names are shipped
   through `watermark_payload`, `watermark_scoped_to_categories`, and
   `watermarking_enabled` in [plugin.rb](../../plugin.rb) (lines 40–60), the
   client-visible `user_fingerprint_*` settings in
   [settings.yml](../../config/settings.yml), and JavaScript module names.
   Rename serializer fields only as a separate, coordinated contract change
   if reducing those labels is also a requirement. Leave descriptive internal
   and admin names useful for maintainers. Random selectors and closed Shadow
   DOM do not provide a confidentiality boundary.

4. **Add regression coverage that observes the rendered result.** The existing
   [acceptance test](../../test/javascripts/acceptance/watermark-overlay-test.js)
   checks the authored `element.style` colour; the
   [system spec](../../spec/system/watermark_overlay_spec.rb) checks presence and
   the mask. Both can pass during this failure. Assert computed colour and
   blend mode, then compare marked/unmarked screenshots on controlled light,
   dark, and coloured backgrounds. At default settings, require unchanged red
   and green with blue differences bounded by two levels in the controlled
   fixture, and require a nonzero encoded signal. A missing overlay must not
   count as success.

   Run the existing extractor and verify the expected test payload. In this
   audit it appeared in the top 12 candidates for corrected Firefox and
   Chromium screenshots, both PNG and JPEG quality 70, using the known scale
   of 1. This establishes recovery for the synthetic fixture; it does not
   establish performance on arbitrary content, crops, downscales, or a real
   account's signature. A release test must also resolve an authenticated test
   account through the server decoder.

**Release verification should cover the extension beyond this engine fixture.**

| Area | Required coverage |
|---|---|
| Real extension | Firefox with the installed Mozilla add-on; Chromium extension; record exact versions and settings |
| Theme modes | Dynamic, Static, Filter, and Filter+ where supported; native Discourse light/dark palettes |
| Timing | Extension enabled before load, enabled afterward, disabled/re-enabled, SPA navigation, teardown/remount |
| Rendering | Settings 4 and 8 plus supported stronger settings; desktop/mobile, DPR/zoom, text and image-heavy content |
| Recovery | PNG, JPEG, representative crops/resizes, successful server decode, and unmarked negative controls |
| Print | Preview, cancel, repeated print, PDF capture and extraction, restoration of screen paint |
| Existing behaviour | Anonymous/disabled/excluded routes and categories, pointer/keyboard/selection behaviour, no duplicate overlays |

Dynamic mode rewrites styles; Filter and Filter+ operate through page filtering,
and Static uses a different stylesheet strategy. The proposed declaration fix
does not establish correctness for all these modes. See
[Dark Reader's mode descriptions](https://darkreader.org/help/en/#theme-generation-modes).

**Several tempting alternatives should not be the default repair.** An
`IGNORE INLINE STYLE` site fix is a valid operator workaround, but requires
extension configuration/distribution; it is not an HTML opt-out attribute.
See the [upstream fixes documentation](https://github.com/darkreader/darkreader/blob/main/CONTRIBUTING.md).
Renaming the div alone cannot fix recolouring. Merely moving the colour into a
stylesheet remains exposed to stylesheet analysis. Repeated mutation observers
that undo Dark Reader's work create competing update loops. Disabling Dark
Reader for the entire site or hiding the watermark whenever it is detected
would respectively interfere with the user's theme choice or remove coverage.

A canvas or raster carrier is worth prototyping only if the broader extension
matrix exposes failures the small fix cannot address. It can move signal
colours out of ordinary CSS colour rewriting, but the element is still
discoverable, filters can still affect it, and DPR, resizing, print, and
extraction all need fresh validation. Changing the renderer adds substantially
more work than the demonstrated compatibility repair.

**Correct the visibility claims while updating the tests.** The README's
configuration table calls one blue level “invisible on any display”; that is
not a defensible guarantee. Its manual checks describe palette-colour blocks
and restoring setting `20`, although the current renderer uses a fixed blue
carrier and the configured default is `8`. The code comments also describe
constant subtraction on every background. Difference blending actually gives
`B_out = abs(B_background - k)` at fully covered pixels, so the signed change
depends on the background and can vanish at `B_background = k/2`.
See the [blend specification](https://www.w3.org/TR/compositing-1/#blendingdifference).
Describe the watermark as a small, measured signal under tested conditions;
state the visibility/recovery tradeoff without promising universal invisibility.

**Reproduction assets and limits.**

The [Chromium results](dark-reader-2026-09-18/chromium-results.json),
[Firefox results](dark-reader-2026-09-18/firefox-results.json), and
[extraction results](dark-reader-2026-09-18/extraction-results.json) retain the
measurements. The harness executes downloaded JavaScript only after checking
the recorded SHA-256. It needs Python packages `playwright`, `numpy`, and
`Pillow`, plus Playwright browser installations. From the repository root:

```sh
mkdir -p /tmp/darkreader-audit
curl -fL https://unpkg.com/darkreader@4.9.131/darkreader.js \
  -o /tmp/darkreader-audit/darkreader.js
python3 docs/audits/dark-reader-2026-09-18/reproduce.py --matrix
python3 docs/audits/dark-reader-2026-09-18/reproduce.py --matrix --engine firefox
```

With the audited revision, both commands intentionally exit 1 because the
unchanged renderer fails the visual-amplitude check. The candidate variants
are applied only inside the temporary browser page. The library checksum is
`67dffb98fd5be7815de32578d2c3d3af60e30cc94bb94f325e59aaf6294ee7fd`.
No full Discourse suite, installed-extension integration, other theme engines,
physical-display visibility study, or production deployment was performed.
