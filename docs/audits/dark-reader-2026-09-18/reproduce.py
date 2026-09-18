import io
import json
import re
import sys
import argparse
import hashlib
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image
from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[3]
AUDITED_REVISION = '9614803771b2a290529c144b48989bf125028273'
OUT = Path('/tmp/darkreader-audit')
DARKREADER = {
    'version': '4.9.131',
    'source': 'https://unpkg.com/darkreader@4.9.131/darkreader.js',
    'sha256': '67dffb98fd5be7815de32578d2c3d3af60e30cc94bb94f325e59aaf6294ee7fd',
}
parser = argparse.ArgumentParser()
parser.add_argument('--engine', choices=['chromium', 'firefox'], default='chromium')
parser.add_argument('--matrix', action='store_true')
args = parser.parse_args()
OUT.mkdir(exist_ok=True)
if hashlib.sha256((OUT / 'darkreader.js').read_bytes()).hexdigest() != DARKREADER['sha256']:
    raise SystemExit('Unexpected Dark Reader build; download the pinned version in the audit report.')
def original_source(path):
    return subprocess.check_output(
        ['git', '-C', str(ROOT), 'show', f'{AUDITED_REVISION}:{path}'], text=True
    )


css = original_source('assets/stylesheets/common/discourse-watermarking.scss')
css = '\n'.join(line for line in css.splitlines() if not line.lstrip().startswith('//'))
lib = original_source('assets/javascripts/discourse/lib/watermark.js').replace('export ', '')
initializer = original_source('assets/javascripts/discourse/initializers/discourse-watermarking.js')
initializer = re.sub(r'import\s+[\s\S]*?;\s*', '', initializer)
initializer = initializer.replace('export default', 'window.initializer =')
bootstrap = '''
window.withPluginApi = (fn) => fn({onPageChange: (fn) => { window.pageChange = fn; fn(); }});
window.owner = { lookup: (key) => ({
 'service:site-settings': {user_fingerprint_enabled: true, user_fingerprint_strategy: 'visual',
  user_fingerprint_visual_density: 32, user_fingerprint_visual_opacity: 8},
 'service:current-user': {watermark_payload: 'c5109c112371258d'},
 'service:router': {currentRouteName: 'topic.show', currentURL: '/t/example/1'},
 'controller:topic': {model: {watermarking_enabled: true}}
})[key]};
window.initializer.initialize(window.owner);
'''

def capture(page, name):
    data = page.evaluate('''() => {
      const el = document.getElementById('discourse-watermark-overlay');
      const s = getComputedStyle(el);
      return {background: s.backgroundColor, opacity: s.opacity, blend: s.mixBlendMode,
        mask: s.maskImage.startsWith('url('), inline: el.style.backgroundColor,
        darkreaderAttributes: el.getAttributeNames().filter(x => x.includes('darkreader'))};
    }''')
    marked = np.asarray(Image.open(io.BytesIO(page.screenshot(path=str(OUT / f'{name}.png')))).convert('RGB')).astype(int)
    page.evaluate("document.getElementById('discourse-watermark-overlay').style.visibility = 'hidden'")
    clean = np.asarray(Image.open(io.BytesIO(page.screenshot())).convert('RGB')).astype(int)
    page.evaluate("document.getElementById('discourse-watermark-overlay').style.visibility = ''")
    diff = np.abs(marked - clean)
    data['max_channel_delta'] = diff.max(axis=(0, 1)).tolist()
    data['changed_pixel_fraction'] = float(np.mean(np.any(diff > 0, axis=2)))
    return data

variants = {'current': ''}
if args.matrix:
    variants.update({
      'inline-important': "el.style.setProperty('background-color', el.style.backgroundColor, 'important');",
      'ignore-attribute': "el.setAttribute('data-darkreader-ignore', '');",
      'ignore-inline-fix': '',
      'without-mask': "el.style.maskImage = 'none';",
      'element-opacity-cap': "el.style.opacity = 2 / 255;",
    })
with sync_playwright() as p:
    browser = getattr(p, args.engine).launch(headless=True)
    results = {'browser': browser.version, 'darkreader': DARKREADER, 'variants': {}}
    for name, change in variants.items():
        page = browser.new_page(viewport={'width': 1024, 'height': 768}, device_scale_factor=1)
        page.set_content('<html><head><style>html,body {margin:0; background:white; color:black;} body {min-height:100vh;}</style></head><body></body></html>')
        page.add_style_tag(content=css)
        page.add_script_tag(content=lib + '\n' + initializer + '\n' + bootstrap)
        page.evaluate("() => {const el = document.getElementById('discourse-watermark-overlay');" + change + "}")
        result = {'before': capture(page, f'{args.engine}-{name}-before')}
        page.add_script_tag(path=str(OUT / 'darkreader.js'))
        fixes = {'ignoreInlineStyle': ['#discourse-watermark-overlay']} if name == 'ignore-inline-fix' else {}
        page.evaluate('(fixes) => DarkReader.enable({brightness:100, contrast:100, sepia:0}, fixes)', fixes)
        page.wait_for_timeout(800)
        result['after'] = capture(page, f'{args.engine}-{name}-after')
        if name in ['current', 'inline-important']:
            page.evaluate('DarkReader.disable()')
            page.emulate_media(media='print')
            result['print_without_darkreader'] = capture(page, f'{args.engine}-{name}-print')
        if name == 'inline-important':
            page.emulate_media(media='screen')
            lifecycle = []
            for theme in [{'brightness':100, 'contrast':100, 'sepia':0},
                          {'brightness':80, 'contrast':120, 'sepia':20}]:
                page.evaluate('(theme) => DarkReader.enable(theme)', theme)
                page.wait_for_timeout(300)
                lifecycle.append(capture(page, f'{args.engine}-{name}-toggle-{len(lifecycle)}'))
                page.evaluate('DarkReader.disable()')
            page.evaluate('DarkReader.enable({brightness:100, contrast:100, sepia:0})')
            page.evaluate('window.initializer.teardown()')
            patched_initializer = initializer.replace('overlay.style.backgroundColor = `rgb(0 0 ${amplitude})`;',
                "overlay.style.setProperty('background-color', `rgb(0 0 ${amplitude})`, 'important');")
            page.add_script_tag(content='(() => {' + patched_initializer + '\nwindow.initializer.initialize(window.owner);})()')
            page.wait_for_timeout(300)
            lifecycle.append(capture(page, f'{args.engine}-{name}-remount'))
            result['lifecycle'] = lifecycle
            assert all(x['background'] == 'rgb(0, 0, 2)' and max(x['max_channel_delta']) <= 2 for x in lifecycle)
        results['variants'][name] = result
        print(name, json.dumps(result), flush=True)
        page.close()
    (OUT / f'{args.engine}-results.json').write_text(json.dumps(results, indent=2))
    browser.close()
    if max(results['variants']['current']['after']['max_channel_delta']) > 2:
        print('FAIL: Dark Reader amplified the overlay beyond the configured 2 levels')
        sys.exit(1)
