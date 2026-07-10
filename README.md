# discourse-watermarking

Per-user forensic watermarking for Discourse. When content from a restricted
forum area leaks as a screenshot or copied text, this plugin lets
administrators trace the leak back to the account that was logged in when the
content was rendered — without ever embedding identifying information in the
page.

> **Honest framing:** this is an attribution aid, not DRM. A determined
> adversary can defeat any client-side watermark (see
> [Limitations and likely bypasses](#limitations-and-likely-bypasses)).
> The goal is to make casual and careless leaking attributable, raise the
> cost of deliberate leaking, and deter both.

---

## Table of contents

- [Architecture](#architecture)
- [Watermark design](#watermark-design)
- [Why this approach — alternatives considered](#why-this-approach--alternatives-considered)
- [Cryptography](#cryptography)
- [Installation](#installation)
- [Configuration](#configuration)
- [Secret rotation](#secret-rotation)
- [Decoding workflow](#decoding-workflow)
- [Text fingerprinting (optional)](#text-fingerprinting-optional)
- [Privacy considerations](#privacy-considerations)
- [Legal considerations](#legal-considerations)
- [Limitations and likely bypasses](#limitations-and-likely-bypasses)
- [Extension points](#extension-points)
- [Testing](#testing)
- [Manual verification guide](#manual-verification-guide)

---

## Architecture

```
                     ┌──────────────────────────────────────────────┐
                     │ Server                                       │
 user_id ──HMAC──►   │ lib/discourse_watermarking/payload.rb        │
 (secret)            │   64-bit tile: sync ▪ version ▪ user code ▪  │
                     │   integrity tag                              │
                     └──────────────┬───────────────────────────────┘
                                    │ CurrentUserSerializer.watermark_payload
                                    │ (opaque hex, no PII)
                     ┌──────────────▼───────────────────────────────┐
                     │ Client                                       │
                     │ initializers/discourse-watermarking.js       │
                     │   • fixed full-viewport overlay div          │
                     │   • SVG mask tile over pure-blue background  │
                     │   • copy-event zero-width fingerprint (opt.) │
                     └──────────────┬───────────────────────────────┘
                                    │ screenshot leaks
                     ┌──────────────▼───────────────────────────────┐
                     │ Recovery                                     │
                     │ tools/extract_watermark.py → candidate hex   │
                     │ /admin/plugins/discourse-watermarking        │
                     │   decoder: verify tag → resolve user code    │
                     └──────────────────────────────────────────────┘
```

Server components:

| Piece | File | Role |
|---|---|---|
| Payload codec | `lib/discourse_watermarking/payload.rb` | HMAC user codes, integrity tags, tile bytes |
| Eligibility | `lib/discourse_watermarking/eligibility.rb` | central scope rules (groups, categories, bots, anonymous) |
| Decoder | `lib/discourse_watermarking/decoder.rb` | payload parsing, signature verification, user resolution |
| Zero-width codec | `lib/discourse_watermarking/zero_width.rb` | text fingerprint encode/decode |
| Secret management | `lib/discourse_watermarking/secret.rb` | generation, rotation, non-sensitive fingerprint |
| Admin API | `app/controllers/discourse_watermarking/admin_watermarking_controller.rb` | status / decode / rotate endpoints |
| Audit trail | `app/models/discourse_watermarking/decode_audit.rb` + migration | who decoded what, when |

Client components:

| Piece | File | Role |
|---|---|---|
| Overlay + copy handler | `assets/javascripts/discourse/initializers/discourse-watermarking.js` | renders/removes the overlay on route changes |
| Pure helpers | `assets/javascripts/discourse/lib/watermark.js` | bit codec, SVG tile builder, route exclusion rules |
| Admin UI | `admin/assets/javascripts/…` | decoder page, diagnostics, secret rotation |

Integration uses only documented extension points: `add_to_serializer`,
`add_admin_route`, site settings, an engine with its own routes, and a
standard client initializer. **No monkey-patching of core.**

## Watermark design

### The visual layer

The watermark is a **periodic 8×8 grid of large, soft-edged blocks** rendered
by a single fixed-position, pointer-transparent overlay covering the
viewport:

- Each cell is `user_fingerprint_visual_density` CSS px (default **32 px ≈
  8.5 mm** at nominal CSS DPI), so one tile is 256×256 px and repeats across
  the whole viewport.
- A `1` bit renders a rounded, slightly blurred filled square; a `0` bit
  renders nothing.
- The pattern is applied as a CSS `mask-image` over
  `background-color: #00f` (pure blue) at ~2% opacity
  (`user_fingerprint_visual_opacity`, in per-mille). Blue is deliberate: the
  signal rides the blue-yellow **chroma** axis, where human contrast
  sensitivity is weakest — at equal amplitude a chroma shift is far less
  perceptible than the brightness shift a gray overlay produces. It also
  makes recovery *easier*: forum content is overwhelmingly neutral gray, so
  in the extraction tool's chroma plane (`B − (R+G)/2`) text, borders, and
  scrollbars cancel out while the watermark survives at full strength.
  Works identically on light and dark palettes (both shift slightly toward
  blue where a bit is set), with no per-theme configuration.

Why large soft blocks instead of fine dots or text? Because everything that
happens to a leaked screenshot — device downscaling, messaging-app
recompression, JPEG quantization, screen-to-camera capture — is a **low-pass
process**: it destroys fine detail and preserves coarse, low-spatial-frequency
structure. Large blocks *are* low-frequency structure. In verification runs
against real dark-theme forum screenshots, the extraction tool places the
exact payload at rank 1 from lossless captures and from JPEG quality-70
recompression at the default 2% opacity. One honest limit: heavy *combined*
degradation (50% downscale **plus** JPEG q70) deterministically rounds a
~2-level chroma signal away on flat regions — surviving that needs opacity
around 4–5%, which trades away invisibility. Raise
`user_fingerprint_visual_opacity` for high-risk areas if that scenario
matters more than subtlety.

The 64-bit tile layout (row-major in the 8×8 grid):

```
byte 0      0xC5  sync byte (asymmetric → orientation + alignment)
byte 1      version (high nibble) | reserved
bytes 2..5  user code   = HMAC-SHA256(secret, user id)[0..3]
bytes 6..7  integrity tag = HMAC-SHA256(secret, bytes 1..5)[0..1]
```

Because the tile repeats periodically, **any crop containing roughly two tile
periods (~512 CSS px) of content is decodable** — every cell of the pattern is
observed regardless of where the crop starts, and the extraction tool
searches all cyclic shifts, rotations, mirrorings, and polarities.

### Determinism and statelessness

The payload is a pure function of `(secret, user_id)`:

- same user, same secret → same watermark on every request, session, device,
  and page load;
- decoding needs **no session logs or historical records** — the decoder
  recomputes the user code for every account and compares in constant time;
- rotating the secret atomically re-keys every user.

### Scope rules

Watermarks are only emitted when **all** of the following hold
(`lib/discourse_watermarking/eligibility.rb`):

- plugin enabled and secret configured;
- a real, logged-in, non-staged, non-bot user (crawlers and anonymous
  visitors get the crawler/no-user serializers and receive nothing);
- the user is in `user_fingerprint_enabled_groups` (or no restriction is set);
- for topic views, the topic's category is in
  `user_fingerprint_enabled_categories` (or no restriction is set). When a
  category restriction is active, non-topic pages are not watermarked, and
  the client is told only *that* a restriction exists — never which
  categories.

The client additionally never renders the overlay on admin, login, signup,
invite, wizard, password-reset, or account-activation routes.

### Mobile

Mobile is a first-class target, not an afterthought:

- The overlay is a fixed-position element sized by the visual viewport — it
  needs no per-post decoration, so infinite scrolling, dynamically loaded
  posts, and virtualized post streams are irrelevant to it.
- Cells are sized in CSS px, so high-DPI ("Retina", 2×–3× DPR) screens render
  the same physical pattern, just sharper. The extraction tool sweeps a
  0.5×–4× scale range to cover any DPR, browser zoom, or post-hoc resize.
- A 390 px-wide phone viewport shows ~1.5 tiles horizontally and ~3 vertically
  — full-screen mobile screenshots (Android and iOS) contain several complete
  observations of the payload.
- `pointer-events: none` keeps touch scrolling, selection, and gestures
  untouched.

### Accessibility and visual impact

The overlay carries `aria-hidden="true"`, no content, no pointer events, and
~2% opacity on the blue-yellow chroma axis — a few brightness levels of blue
shift with no meaningful luminance change, below the threshold where flat
color patches become noticeable. It does not affect contrast ratios, does
not repaint (static element), and does not interfere with selection,
scrolling, or assistive technology.

## Why this approach — alternatives considered

| Approach | Verdict | Reasoning |
|---|---|---|
| **Tiled low-frequency block grid via CSS mask, blue-chroma carrier (chosen)** | ✅ | Survives JPEG (verified on live screenshots); near-invisible (chroma axis); gray page content cancels out of the recovery plane; one inert DOM node; crop-tolerant through periodicity; trivial to disable-detect… nothing is perfect |
| Fine dot patterns / pixel-level steganography | ❌ | Destroyed by the very first downscale or JPEG pass (confirmed experimentally — this design started with 2–3 px dots and they did not survive); DPR scaling smears single pixels |
| Repeated semi-transparent username text | ❌ | Trivially recognized and removed; requires OCR-resistant obfuscation; visually intrusive at recoverable opacities; embeds PII |
| Luminance modulation of the page background color itself | ⚠️ Rejected | Same signal class as the chosen approach but requires rewriting theme backgrounds (fights themes/palettes instead of riding on them) and breaks on images/full-bleed content; the mask overlay achieves the same spectral properties non-invasively |
| Canvas-generated overlays | ⚠️ Rejected | Equivalent output to the SVG mask but more code, CSP `canvas` fingerprinting noise, and no benefit; SVG-in-CSS is declarative and theme-aware |
| Per-post DOM decoration (decorateCookedElement) | ⚠️ Rejected | Must track every dynamically loaded post; misses chrome/UI around posts; more DOM churn on infinite scroll; the viewport overlay covers everything with one node |
| Micro-geometric text perturbations (word/letter spacing jitter) | ⚠️ Rejected | Low capacity, destroyed by reflow at different viewport widths (fatal on mobile), hard to decode from photos |
| Alpha-channel modulation of uploaded images | ⚠️ Out of scope | Only protects images, not rendered text; belongs in a future server-side image pipeline extension (see [Extension points](#extension-points)) |
| Zero-width character text fingerprint | ✅ as **optional secondary** | Perfect fidelity for copy/paste leaks, zero visual impact — but detectable and strippable; therefore opt-in and documented (see below) |

The hybrid strategy (`visual` + `text`) covers the two dominant leak channels
(screenshots and copied text) with complementary techniques.

## Cryptography

All primitives are HMAC-SHA256 with a server-side secret
(`user_fingerprint_secret`, generated as 64 hex chars / 256 bits of
`SecureRandom` entropy on first enable):

- **User code** (32 bits): `HMAC-SHA256(secret, "discourse-watermarking:user:v1:<id>")`,
  truncated. A keyed pseudonym: without the secret it cannot be reversed,
  correlated across sites, or precomputed. 32 bits keeps the on-screen
  payload small (recoverability beats collision paranoia at forum scale;
  collisions are ~n²/2³³ — about 0.5% at 100k users — and are *detected and
  reported* by the decoder, which returns every matching account).
- **Integrity tag** (16 bits): HMAC over the versioned payload body,
  truncated. An attacker without the secret cannot construct a payload that
  passes verification except by 1-in-65,536 chance per attempt — and the
  decoder is authenticated, audited, and rate-limited (20/min, staff
  included), so forging a payload that frames another user is not practical.
  A forged payload must *also* hit an existing account's user code
  (probability n/2³²).
- **Verification** uses `ActiveSupport::SecurityUtils.fixed_length_secure_compare`
  (constant-time) for both the tag and every user-code comparison.
- Truncation of HMAC-SHA256 output is a standard, safe construction
  (NIST SP 800-107); the short lengths here are a deliberate
  capacity/robustness trade-off, compensated by authentication, rate
  limiting, and auditing of the only oracle (the decoder).

Why not encryption (e.g. AES-GCM of the user id)? An authenticated ciphertext
carrying a user id needs ≥128 bits plus tag — over 3× the payload, which
directly costs screenshot recoverability (more/smaller cells). The
HMAC-pseudonym design gets authentication and irreversibility at 56 bits, at
the cost of an O(users) scan on decode (milliseconds per 100k users — HMACs
are cheap) — the right trade for this use case.

Other security properties:

- The secret never reaches the client; the payload is opaque hex.
- `secret: true` site setting → password input, scrubbed from logs.
- Decoder and status endpoints: admin-only by default
  (`user_fingerprint_staff_only_decoder`; disabling extends access to
  moderators, never further). Secret rotation is admin-only, always.
- Standard Rails CSRF protection applies (all mutating endpoints are POST
  under `ApplicationController`).
- Every decode attempt is written to `discourse_watermarking_decode_audits`
  (actor, SHA-256 of input, result, matched user) and shown on the admin
  page — the decoder itself is a surveillance-capable tool, so it gets an
  audit trail.
- All output rendering uses Ember's escaped `{{ }}` bindings; the SVG mask is
  built from a validated hex string only.

## Installation

```bash
cd /var/discourse
# containers/app.yml — add to the plugins section:
hooks:
  after_code:
    - exec:
        cd: $home/plugins
        cmd:
          - git clone https://github.com/your-org/discourse-watermarking.git

./launcher rebuild app
```

For a development install:

```bash
ln -s /path/to/discourse-watermarking ~/discourse/plugins/discourse-watermarking
bin/rails db:migrate
```

Requirements: a current Discourse (2025+ tested), no extra services. The
optional extraction tool needs Python 3 with `pillow` and `numpy`.

## Configuration

All settings live under **Admin → Settings → Plugins → Watermarking** (or the
plugin's page under **Admin → Plugins**):

| Setting | Default | Meaning |
|---|---|---|
| `user_fingerprint_enabled` | `false` | Master switch. A secret is auto-generated on first enable. |
| `user_fingerprint_secret` | *(empty)* | 256-bit key; manage via the rotation button, not by hand. |
| `user_fingerprint_enabled_groups` | *(empty = everyone logged in)* | Watermark only members of these groups. |
| `user_fingerprint_enabled_categories` | *(empty = everywhere)* | Watermark only topics in these categories. |
| `user_fingerprint_strategy` | `visual` | `visual`, `text`, or `hybrid`. |
| `user_fingerprint_visual_opacity` | `20` | **Per-mille**, an integer: 20 = 2%. Values below ~5 fall under 8-bit display quantization and render *nothing* (fractional values like `0.025` silently become zero signal). 15–25 is the sweet spot; raise toward 40–50 only for high-risk areas where downscale+recompression robustness beats subtlety. |
| `user_fingerprint_visual_density` | `32` | Cell size in CSS px. Bigger cells → survives harsher recompression; smaller cells → survives tighter crops. |
| `user_fingerprint_text_enabled` | `false` | Opt-in for the zero-width copy fingerprint. Read [Text fingerprinting](#text-fingerprinting-optional) first. |
| `user_fingerprint_staff_only_decoder` | `true` | `true`: decoder is admin-only. `false`: moderators may also decode. |

Everything defaults to **off / most restrictive**.

## Secret rotation

**Admin → Plugins → Watermarking → Secret rotation → Rotate secret.**

- Rotation immediately re-keys every user's watermark.
- Payloads recovered from screenshots taken **before** the rotation can no
  longer be decoded (the decoder reports `invalid_signature`). Decode pending
  evidence first.
- Rotate whenever you suspect the secret leaked (it lives in the site
  settings table and in database backups), on your normal key-rotation
  schedule, or to deliberately void all outstanding watermarks.
- The admin page shows a non-sensitive 8-hex-char *secret fingerprint* so you
  can tell which key a given site/backup is using without exposing it.

## Decoding workflow

1. **Obtain the leaked artifact** (screenshot image or copied text).
2. **Screenshots:** run the extraction tool:

   ```bash
   pip install pillow numpy
   python3 tools/extract_watermark.py leaked.png
   # Candidate payloads (paste into the admin decoder, best first):
   #   c51fa2b3c4d5e6f7    (score 14.07)
   #   ...
   ```

   Options: `--cell N` if you changed `user_fingerprint_visual_density`,
   `--min-scale/--max-scale` for unusual DPR/zoom/resizes, `--top N` for more
   candidates, `--plane chroma|luma` to pin the analysis plane (default:
   both). Copy the whole output block. Cropping the screenshot to a
   content-light region (margins, empty columns) often sharpens the result.
3. **Copied text:** skip the tool — paste the text itself.
4. Open **Admin → Plugins → Watermarking** and paste into the decoder. It
   accepts hex (14/16 chars), raw bits (56/64), text containing a zero-width
   fingerprint, or the tool's entire output (each candidate is tried; the
   cryptographic tag picks the right one). Extraction noise is tolerated:
   the decoder also searches 1- and 2-bit variants of each candidate, and
   reports `corrected (N flipped bits)` as the confidence when that path
   found the match.
5. Read the result:
   - **Match found** — signature valid, resolved to an account, confidence
     `high` (or `ambiguous` with all accounts listed in the astronomically
     rare user-code collision case).
   - **Valid signature, no account** — the account was deleted after the leak.
   - **Invalid signature** — forged/corrupted payload *or* generated before a
     secret rotation.
   - **No payload found** — input not recognized.
6. Every attempt lands in the audit log on the same page.

Treat a match as **one piece of evidence, not proof** — see limitations.

## Text fingerprinting (optional)

When `user_fingerprint_text_enabled` and strategy `text`/`hybrid`:

- A `copy` event handler appends an invisible suffix — a 4-character marker
  plus 32 characters from a four-symbol zero-width alphabet (ZWSP, ZWNJ, ZWJ,
  WORD JOINER), encoding the same 64-bit tile — to the copied plain text.
- It **never** modifies the post content itself, so Markdown, search,
  quotes, oneboxes, mentions, emoji, and URLs are untouched by construction —
  the cooked HTML never changes.
- It skips: selections shorter than 24 chars, selections inside
  `pre`/`code`/`kbd`/`samp`, inputs, textareas, and contenteditable (your own
  drafts and copied code never get invisible characters), and events another
  handler already processed.

**Read before enabling — inherent trade-offs:**

- Zero-width characters are **detectable**: paste into a hex editor, an IDE
  with invisible-character highlighting (most modern editors warn), or run
  a stripping tool, and they are visible/removable.
- Some paste targets mangle or reveal them; pasting into terminals or code
  review tools can confuse users.
- Sophisticated leakers strip them trivially. Treat this layer as catching
  casual copy-paste leaks only.

The server-side codec (`ZeroWidth`) decodes fingerprints from pasted leak
text in the same admin decoder.

## Privacy considerations

- **No PII in the payload.** Usernames, user ids, emails, IPs, session or
  request identifiers are never embedded — the payload is a keyed pseudonym
  plus checksum, meaningless without the server secret.
- **Watermarks are per-user tracking.** Even pseudonymous, this is a form of
  user-linked marking. Depending on jurisdiction (e.g. GDPR), disclose it in
  your privacy policy / ToS; the pseudonymous payload is still *personal
  data* while the secret exists, because the operator can resolve it.
- **Decoder is the only oracle** and is authenticated, rate-limited, and
  audited. Audit records store a hash of the input, not the input itself.
- **No cross-site correlation:** codes are secret-scoped; two forums cannot
  link users by comparing watermarks.
- Users are not notified per-page (that would defeat the purpose); community
  rules should disclose that restricted areas are watermarked — which is
  itself a deterrent.

## Legal considerations

Not legal advice. Points to review with counsel before deploying:

- **Disclosure duties** (GDPR Art. 13/14, ePrivacy, CCPA and similar):
  watermarking is processing of personal data for leak attribution —
  document the lawful basis (usually legitimate interest) and mention it in
  the privacy policy.
- **Proportionality:** scope it with groups/categories to the areas that
  actually need protection rather than the whole forum.
- **Evidence quality:** a decoded watermark shows *whose session rendered the
  leaked content* — not who photographed the screen, who shared it onward,
  or that the account wasn't compromised. Treat it as investigative lead,
  not conviction.
- **Employment/works councils:** if members are employees, monitoring rules
  may apply.

## Limitations and likely bypasses

Assume a motivated adversary can defeat this. Known bypasses:

| Bypass | Effect | Mitigation |
|---|---|---|
| Manual transcription / retyping | Complete | None (inherent to any watermark) |
| OCR of a screenshot | Defeats visual + text layers | None; deterrence only |
| CSS stripping (devtools, extensions, reader mode, `display:none` on the overlay) | Removes visual layer | Detection is possible but an arms race; not attempted |
| Browser extensions / user scripts | Remove overlay, strip zero-width chars | Same as above |
| Heavy image editing (paint-over, strong noise, posterize) | Destroys pattern | Higher opacity raises the required effort |
| Aggressive cropping (< ~2 tile periods, ~512 CSS px) | Too little signal | Smaller `visual_density` trades recompression robustness for crop robustness |
| Extreme recompression/rescaling (far beyond messaging-app defaults) | Signal below noise | Raise `visual_opacity` for high-risk areas |
| Collusion (N users diff their screenshots) | Reveals & removes marks | Inherent to deterministic per-user marks; probabilistic/time-varying marks would trade determinism |
| Copy-paste via API/RSS or quoting | Bypasses both layers | Out of scope; server-side text fingerprinting extension possible |
| Screenshot of a *photo* of the screen (analog hole) | Usually survives! Low-frequency marks tolerate moderate perspective/moiré | Use the extraction tool; success varies |

Also note:

- The overlay is client-side: content delivered over the API, in emails, or
  to crawlers is not marked.
- Users can see the overlay element in devtools; the *payload* reveals
  nothing, but the *presence* of watermarking is discoverable. (Treat that as
  a feature: deterrence.)
- Very image-heavy pages give the extractor less clean background to fold;
  recovery quality varies with content.

## Extension points

- **Payload versioning:** 4-bit version field; add new formats in
  `Payload`/`Decoder` while keeping v1 decodable.
- **New watermark channels:** `Eligibility` + the serializer payload are
  channel-agnostic. Natural additions: server-side image watermarking on
  upload (imgproxy/libvips pipeline), server-side text fingerprinting for
  API responses, PDF/export marking.
- **Anonymous watermarking:** `Eligibility.watermark_user?` is the single
  gate; a future mode could mark anonymous sessions with an ephemeral-keyed
  code (explicitly out of scope today).
- **SIEM/webhook integration:** subscribe to decode audits
  (`DecodeAudit`) or wrap the decode endpoint.
- **Custom exclusion rules:** route prefixes are data
  (`EXCLUDED_ROUTE_PREFIXES` / `EXCLUDED_URL_PREFIXES` in
  `lib/watermark.js`).

## Testing

Backend (63 examples — payload determinism/uniqueness/rotation, forgery
rejection, eligibility scope rules, decoder correctness for hex/bits/
zero-width/tool-output inputs, serializer inclusion/exclusion, controller
authorization incl. moderator gating, rate limiting, auditing, secret
rotation):

```bash
cd discourse
LOAD_PLUGINS=1 bin/rspec plugins/discourse-watermarking/spec/lib \
  plugins/discourse-watermarking/spec/serializers \
  plugins/discourse-watermarking/spec/requests
```

System specs (real browser: overlay on desktop + mobile topic views, mask
present, anonymous/disabled/admin-page/category-scoped exclusions):

```bash
LOAD_PLUGINS=1 bin/rspec plugins/discourse-watermarking/spec/system
```

Frontend (unit: bit codec, SVG builder, zero-width vector shared with the
Ruby spec, route exclusion; acceptance: overlay rendering across desktop,
mobile, scoped, text-only, disabled, and anonymous configurations):

```bash
LOAD_PLUGINS=1 bin/qunit plugins/discourse-watermarking/test/javascripts
```

Extraction tool: `tools/extract_watermark.py` was validated against
synthetic screenshots (light theme, dark theme, 50% downscale + JPEG q70,
crops down to ~1.8 tile periods) — the correct payload ranked in the top
candidates in every recoverable case.

## Manual verification guide

With the plugin enabled, a test user logged in, and
`user_fingerprint_visual_opacity` temporarily raised to ~80 (8%) so you can
see what you are checking:

1. **Foundation theme + Marigold palette (light):** open a topic — faint
   dark blocks tile the page; verify they follow the palette's text color.
2. **Dark palette:** switch palettes — blocks become *lighter* than the
   background, same layout.
3. **Desktop screenshot:** screenshot a topic, run the extraction tool,
   decode in the admin UI, confirm it resolves to the test user.
4. **Android screenshot:** repeat on Android Chrome (2–3× DPR); the tool's
   scale sweep handles the density change.
5. **iOS screenshot:** repeat on iOS Safari.
6. **Cropped screenshot:** crop to roughly half a phone screen (keep ≥ ~512
   CSS px of content) and confirm recovery.
7. **Both themes:** repeat 3 with light and dark palettes (polarity is
   handled automatically).
8. **Interaction checks:** text selection, link clicks, scrolling, composer,
   and modals must be unaffected; the overlay must be absent on `/admin`,
   `/login`, `/signup`, and for anonymous visitors.
9. Restore the opacity to ~20 (2%) and verify the overlay is not noticeable
   in either theme.

---

### File map

```
plugin.rb                                   registration, serializers, admin route
config/settings.yml                         site settings (safe defaults)
config/routes.rb                            engine + mount under /admin/plugins/…
config/locales/{client,server}.en.yml       i18n
db/migrate/…_create_…_decode_audits.rb      decoder audit table
lib/discourse_watermarking/*.rb             payload, decoder, eligibility, secret, zero-width, engine
app/controllers/…/admin_watermarking_controller.rb
app/models/…/decode_audit.rb
assets/javascripts/discourse/initializers/  overlay + copy handler, admin nav
assets/javascripts/discourse/lib/watermark.js
assets/stylesheets/{common,admin}/          overlay + admin page styles
admin/assets/javascripts/…                  admin route map, decoder page, components
spec/…                                      RSpec: lib, serializers, requests, system
test/javascripts/…                          QUnit: unit + acceptance
tools/extract_watermark.py                  screenshot → payload recovery
```
