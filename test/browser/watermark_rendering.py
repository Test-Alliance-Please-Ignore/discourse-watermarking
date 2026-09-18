"""Exercise the real initializer and CSS with Dark Reader's pinned Dynamic engine.

Only Discourse's service lookup and page-change API are stubbed. Browser pixels,
print media, and the extractor are real. See README.md for dependency setup.
"""

import argparse
import hashlib
import importlib.util
import io
import json
import re
import shutil
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[2]
PAYLOAD = "c5109c112371258d"
DARKREADER_SHA256 = "67dffb98fd5be7815de32578d2c3d3af60e30cc94bb94f325e59aaf6294ee7fd"
REPORTED_FILTER = "invert(1) hue-rotate(180deg) brightness(0.75) contrast(0.9)"
# The fixture has no other aria-hidden divs. Avoid coupling the pixel test to
# the renderer's class name, so it can reproduce the original bug as well.
OVERLAY = "body > div[aria-hidden=true]"


def sources():
    css = (ROOT / "assets/stylesheets/common/discourse-watermarking.scss").read_text()
    # This stylesheet uses CSS syntax apart from full-line SCSS comments.
    css = "\n".join(line for line in css.splitlines() if not line.lstrip().startswith("//"))
    lib = (ROOT / "assets/javascripts/discourse/lib/watermark.js").read_text()
    lib = lib.replace("export ", "")
    initializer = (ROOT / "assets/javascripts/discourse/initializers/discourse-watermarking.js").read_text()
    initializer = re.sub(r"import\s+[\s\S]*?;\s*", "", initializer)
    initializer = initializer.replace("export default", "window.initializer =")
    return css, "(() => {" + lib + "\n" + initializer + "})()"


def new_page(browser, darkreader, background="white", setting=8, enabled_first=False, media="screen"):
    page = browser.new_page(viewport={"width": 1024, "height": 768}, device_scale_factor=1)
    page.emulate_media(media=media)
    page.set_content(f"<html><head><style>html,body {{margin:0;background:{background};color:black;}} body {{min-height:100vh;}}</style></head><body></body></html>")
    css, js = sources()
    page.add_style_tag(content=css)
    page.add_script_tag(content=js)
    page.add_script_tag(path=str(darkreader))
    page.evaluate("""({payload, setting}) => {
      window.pageChanges = [];
      window.withPluginApi = (callback) => callback({onPageChange(fn) {
        pageChanges.push(fn); fn();
      }});
      window.services = {
        'service:site-settings': {user_fingerprint_enabled: true,
          user_fingerprint_strategy: 'visual', user_fingerprint_visual_density: 32,
          user_fingerprint_visual_opacity: setting},
        'service:current-user': {watermark_payload: payload},
        'service:router': {currentRouteName: 'topic.show', currentURL: '/t/example/1'},
        'controller:topic': {model: {watermarking_enabled: true}}
      };
      window.owner = {lookup: (key) => services[key]};
      window.navigate = (route, url, enabled = true) => {
        Object.assign(services['service:router'], {currentRouteName: route, currentURL: url});
        services['controller:topic'].model.watermarking_enabled = enabled;
        pageChanges.forEach((fn) => fn());
      };
    }""", {"payload": PAYLOAD, "setting": setting})
    if enabled_first:
        enable(page)
    page.evaluate("initializer.initialize(owner)")
    return page


def enable(page, theme=None):
    page.evaluate("theme => DarkReader.enable(theme)", theme or {"brightness": 100, "contrast": 100, "sepia": 0})
    page.wait_for_function("document.documentElement.dataset.darkreaderMode === 'dynamic'")
    page.wait_for_timeout(150)


def paint(page):
    return page.locator(OVERLAY).evaluate("""el => {
      const s = getComputedStyle(el);
      return {background: s.backgroundColor, blend: s.mixBlendMode,
        opacity: s.opacity, filter: s.filter, mask: s.maskImage, pointerEvents: s.pointerEvents};
    }""")


def wait_paint(page, color):
    page.wait_for_function("([selector, color]) => {const el = document.querySelector(selector); return el && getComputedStyle(el).backgroundColor === color;}", arg=[OVERLAY, color])


def pixels(page, output):
    marked_bytes = page.screenshot(path=str(output))
    marked = np.asarray(Image.open(io.BytesIO(marked_bytes)).convert("RGB")).astype(int)
    page.locator(OVERLAY).evaluate("el => el.style.visibility = 'hidden'")
    try:
        clean = np.asarray(Image.open(io.BytesIO(page.screenshot())).convert("RGB")).astype(int)
    finally:
        page.locator(OVERLAY).evaluate("el => el.style.visibility = ''")
    return np.abs(marked - clean).max(axis=(0, 1)).tolist()


def screen_check(page, output, amplitude=2):
    delta = pixels(page, output)
    assert delta[0] == delta[1] == 0 and 0 < delta[2] <= amplitude, f"unexpected screen signal: {delta}"
    style = paint(page)
    assert style["background"] == f"rgb(0, 0, {amplitude})", style
    assert style["blend"] == "difference" and style["opacity"] == "1", style
    assert style["filter"] == "none", style
    assert "data:image/svg+xml" in style["mask"] and style["pointerEvents"] == "none", style
    return delta


def recover(images):
    spec = importlib.util.spec_from_file_location("extract_watermark", ROOT / "tools/extract_watermark.py")
    extractor = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(extractor)
    for image in images:
        ranked = extractor.extract(str(image), 32, 1.0, 1.0, None, None, "auto")
        assert PAYLOAD in [payload for payload, _score in ranked[:12]], f"payload not recovered: {image}"
        print(f"PASS extraction: {image.name}", flush=True)


def run(args):
    assert hashlib.sha256(args.darkreader.read_bytes()).hexdigest() == DARKREADER_SHA256, "Use the pinned Dark Reader 4.9.131 API build"
    args.output.mkdir(parents=True, exist_ok=True)
    screenshots = []
    measurements = {}
    with sync_playwright() as p:
        browser = getattr(p, args.engine).launch(headless=True)
        measurements["browser"] = browser.version
        page = new_page(browser, args.darkreader)
        measurements["native"] = screen_check(page, args.output / "native.png")
        enable(page)
        # First assertion reproduces the actual visual bug before the fix.
        png = args.output / "dynamic.png"
        measurements["dynamic"] = screen_check(page, png)
        assert page.locator(OVERLAY).get_attribute("id") is None
        assert page.locator(OVERLAY).get_attribute("class") == "d-view-layer"

        # A site-specific inversion rule filters the painted element without
        # changing its computed background colour. This escaped the API-only
        # test and was reported with a one-level blue signal in production.
        # Keep the rule active through navigation, remounting, and printing.
        page.add_style_tag(content=f"html body > .d-view-layer {{filter: {REPORTED_FILTER} !important;}}")
        png = args.output / "element-filter.png"
        measurements["element_filter"] = screen_check(page, png)
        screenshots.append(png)
        Image.open(png).convert("RGB").save(png.with_suffix(".jpg"), quality=70)
        screenshots.append(png.with_suffix(".jpg"))

        page.evaluate("navigate('topic.show', '/t/example/2')")
        assert page.locator(OVERLAY).count() == 1
        page.evaluate("navigate('admin.index', '/admin')")
        assert page.locator(OVERLAY).count() == 0
        page.evaluate("navigate('topic.show', '/t/example/1')")
        screen_check(page, args.output / "navigation.png")
        page.evaluate("DarkReader.disable()")
        enable(page, {"brightness": 80, "contrast": 120, "sepia": 20})
        screen_check(page, args.output / "adjusted.png")

        # Print-media changes must work without relying on beforeprint events.
        page.emulate_media(media="print")
        wait_paint(page, "rgb(0, 0, 255)")
        assert paint(page)["blend"] == "normal" and paint(page)["opacity"] == "0.012"
        page.emulate_media(media="screen")
        wait_paint(page, "rgb(0, 0, 2)")

        # before/afterprint cover print dialogs, including cancellation/repeat.
        for _ in range(2):
            page.evaluate("dispatchEvent(new Event('beforeprint'))")
            wait_paint(page, "rgb(0, 0, 255)")
            page.evaluate("dispatchEvent(new Event('afterprint'))")
            wait_paint(page, "rgb(0, 0, 2)")
        page.evaluate("dispatchEvent(new Event('beforeprint')); navigate('admin.index', '/admin'); navigate('topic.show', '/t/example/1')")
        wait_paint(page, "rgb(0, 0, 255)")
        page.evaluate("dispatchEvent(new Event('afterprint'))")
        wait_paint(page, "rgb(0, 0, 2)")

        # Teardown must leave stale page-change callbacks inert, and reinit must
        # not leave duplicate overlays or print handlers pointing at old nodes.
        page.evaluate("initializer.teardown(); pageChanges.forEach(fn => fn()); dispatchEvent(new Event('beforeprint')); dispatchEvent(new Event('afterprint'))")
        assert page.locator(OVERLAY).count() == 0
        page.evaluate("initializer.initialize(owner); pageChanges.forEach(fn => fn())")
        assert page.locator(OVERLAY).count() == 1
        screen_check(page, args.output / "remounted.png")
        page.evaluate("initializer.initialize(owner); pageChanges.forEach(fn => fn())")
        assert page.locator(OVERLAY).count() == 1

        # Exclusions survive the change from document ID lookup to a reference.
        for script in [
            "navigate('topic.show', '/t/example/1', false)",
            "services['service:current-user'].watermark_scoped_to_categories = true; initializer.initialize(owner); navigate('discovery.latest', '/latest')",
            "services['service:site-settings'].user_fingerprint_strategy = 'text'; initializer.initialize(owner)",
            "services['service:site-settings'].user_fingerprint_enabled = false; initializer.initialize(owner)",
            "services['service:site-settings'].user_fingerprint_enabled = true; services['service:site-settings'].user_fingerprint_strategy = 'visual'; services['service:current-user'] = null; initializer.initialize(owner)",
        ]:
            page.evaluate(script)
            assert page.locator(OVERLAY).count() == 0, script
        page.close()

        for background, setting, amplitude in [("#202020", 8, 2), ("#804020", 8, 2), ("white", 4, 1), ("white", 20, 5)]:
            page = new_page(browser, args.darkreader, background, setting)
            screen_check(page, args.output / f"native-{background.lstrip('#')}-{setting}.png", amplitude)
            enable(page)
            screen_check(page, args.output / f"dynamic-{background.lstrip('#')}-{setting}.png", amplitude)
            page.add_style_tag(content=f"html body > .d-view-layer {{filter: {REPORTED_FILTER} !important;}}")
            png = args.output / f"element-filter-{background.lstrip('#')}-{setting}.png"
            screen_check(page, png, amplitude)
            if setting == 4:
                screenshots.append(png)
                Image.open(png).convert("RGB").save(png.with_suffix(".jpg"), quality=70)
                screenshots.append(png.with_suffix(".jpg"))
            page.close()

        page = new_page(browser, args.darkreader, enabled_first=True, media="print")
        page.add_style_tag(content=f"html body > .d-view-layer {{filter: {REPORTED_FILTER} !important;}}")
        wait_paint(page, "rgb(0, 0, 255)")
        assert paint(page)["filter"] == "none", paint(page)
        page.evaluate("DarkReader.disable()")
        print_png = args.output / "print.png"
        delta = pixels(page, print_png)
        assert delta[0] == delta[1] and 0 < delta[0] <= 4 and delta[2] == 0, delta
        measurements["print"] = delta
        screenshots.append(print_png)
        page.emulate_media(media="screen")
        wait_paint(page, "rgb(0, 0, 2)")
        if args.pdf:
            assert args.engine == "chromium" and shutil.which("pdftoppm"), "PDF check needs Chromium and pdftoppm"
            page.pdf(path=str(args.output / "print.pdf"), width="1024px", height="768px", print_background=True, margin={"top": "0", "right": "0", "bottom": "0", "left": "0"})
            wait_paint(page, "rgb(0, 0, 2)")
            subprocess.run(["pdftoppm", "-scale-to-x", "1024", "-scale-to-y", "768", "-singlefile", "-png", str(args.output / "print.pdf"), str(args.output / "pdf")], check=True, capture_output=True)
            screenshots.append(args.output / "pdf.png")
        page.close()
        browser.close()
    (args.output / "measurements.json").write_text(json.dumps(measurements, indent=2) + "\n")
    print(f"PASS {args.engine}: colour, pixels, print, lifecycle, naming, and exclusions", flush=True)
    if args.extract:
        recover(screenshots)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--engine", choices=["chromium", "firefox"], default="chromium")
    parser.add_argument("--darkreader", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--extract", action="store_true", help="Check PNG, JPEG q70, and print payload recovery (slower)")
    parser.add_argument("--pdf", action="store_true", help="Also capture a real Chromium PDF and rasterize it with pdftoppm")
    run(parser.parse_args())
