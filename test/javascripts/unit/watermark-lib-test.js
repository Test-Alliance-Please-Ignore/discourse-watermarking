import { module, test } from "qunit";
import {
  buildMaskUrl,
  buildTileSvg,
  encodeZeroWidth,
  hexToBits,
  isExcludedRoute,
  ZERO_WIDTH_ALPHABET,
  ZERO_WIDTH_MARKER,
} from "discourse/plugins/discourse-watermarking/discourse/lib/watermark";

const SAMPLE_TILE = "c51fa2b3c4d5e6f7";

module("Unit | Discourse Watermarking | watermark lib", function () {
  test("hexToBits expands hex to 64 bits", function (assert) {
    const bits = hexToBits(SAMPLE_TILE);
    assert.strictEqual(bits.length, 64);
    assert.deepEqual(bits.slice(0, 8), [1, 1, 0, 0, 0, 1, 0, 1], "sync byte");
    assert.strictEqual(hexToBits("zz"), null, "rejects non-hex input");
  });

  test("buildTileSvg renders one block per 1-bit", function (assert) {
    const bits = hexToBits(SAMPLE_TILE);
    const oneBits = bits.filter(Boolean).length;
    const svg = buildTileSvg(SAMPLE_TILE);

    assert.strictEqual((svg.match(/<rect /g) || []).length, oneBits);
    assert.true(svg.includes('viewBox="0 0 8 8"'));
    assert.strictEqual(buildTileSvg("c5"), null, "rejects short payloads");
  });

  test("buildMaskUrl produces an inline data URI", function (assert) {
    const url = buildMaskUrl(SAMPLE_TILE);
    assert.true(url.startsWith('url("data:image/svg+xml,'));
  });

  test("encodeZeroWidth matches the server-side vector", function (assert) {
    // Cross-language vector shared with
    // spec/lib/discourse_watermarking/zero_width_spec.rb
    const encoded = encodeZeroWidth("c500000000000000");
    assert.strictEqual(
      encoded,
      ZERO_WIDTH_MARKER +
        "\u2060\u200B\u200C\u200C" +
        "\u200B".repeat(28)
    );
  });

  test("encodeZeroWidth output is fully invisible", function (assert) {
    const encoded = encodeZeroWidth(SAMPLE_TILE);
    assert.strictEqual(encoded.length, 4 + 32);
    for (const char of encoded) {
      assert.true(ZERO_WIDTH_ALPHABET.includes(char));
    }
  });

  test("isExcludedRoute protects sensitive routes", function (assert) {
    assert.true(isExcludedRoute("admin.dashboard", "/admin"));
    assert.true(isExcludedRoute("login", "/login"));
    assert.true(isExcludedRoute("signup", "/signup"));
    assert.true(isExcludedRoute(null, "/u/password-reset/token"));
    assert.true(isExcludedRoute(null, "/wizard/steps"));

    assert.false(isExcludedRoute("topic.fromParamsNear", "/t/some-topic/280"));
    assert.false(isExcludedRoute("discovery.latest", "/latest"));
    assert.false(isExcludedRoute("userActivity.index", "/u/sam/activity"));
  });
});
