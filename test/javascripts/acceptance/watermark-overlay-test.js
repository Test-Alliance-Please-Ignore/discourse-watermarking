import { visit } from "@ember/test-helpers";
import { test } from "qunit";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";

const PAYLOAD = "c51fa2b3c4d5e6f7";

function overlay() {
  return document.getElementById("discourse-watermark-overlay");
}

acceptance("Discourse Watermarking - visual overlay", function (needs) {
  needs.user({ watermark_payload: PAYLOAD });
  needs.settings({
    user_fingerprint_enabled: true,
    user_fingerprint_strategy: "visual",
    user_fingerprint_visual_opacity: 20,
    user_fingerprint_visual_density: 32,
  });

  test("renders the overlay on a topic", async function (assert) {
    await visit("/t/internationalization-localization/280");

    const element = overlay();
    assert.dom(element).exists("overlay is attached to the page");
    assert.strictEqual(element.getAttribute("aria-hidden"), "true");

    const style = element.style;
    assert.true(
      style.maskImage.includes("data:image/svg+xml"),
      "pattern is applied as a mask"
    );
    assert.strictEqual(style.opacity, "0.02", "opacity follows the setting");
    assert.strictEqual(
      style.maskSize,
      "256px 256px",
      "tile size follows density"
    );
  });

  test("renders the overlay on list pages when unrestricted", async function (assert) {
    await visit("/latest");
    assert.dom(overlay()).exists();
  });
});

acceptance("Discourse Watermarking - mobile", function (needs) {
  needs.mobileView();
  needs.user({ watermark_payload: PAYLOAD });
  needs.settings({
    user_fingerprint_enabled: true,
    user_fingerprint_strategy: "hybrid",
    user_fingerprint_visual_opacity: 20,
    user_fingerprint_visual_density: 32,
  });

  test("renders the overlay in the mobile view", async function (assert) {
    await visit("/t/internationalization-localization/280");
    assert.dom(overlay()).exists();
  });
});

acceptance("Discourse Watermarking - category scoped", function (needs) {
  needs.user({
    watermark_payload: PAYLOAD,
    watermark_scoped_to_categories: true,
  });
  needs.settings({
    user_fingerprint_enabled: true,
    user_fingerprint_strategy: "visual",
    user_fingerprint_visual_opacity: 20,
    user_fingerprint_visual_density: 32,
  });

  test("does not render on list pages when scoped to categories", async function (assert) {
    await visit("/latest");
    assert.dom(overlay()).doesNotExist();
  });
});

acceptance("Discourse Watermarking - text-only strategy", function (needs) {
  needs.user({ watermark_payload: PAYLOAD });
  needs.settings({
    user_fingerprint_enabled: true,
    user_fingerprint_strategy: "text",
    user_fingerprint_text_enabled: true,
  });

  test("does not render an overlay", async function (assert) {
    await visit("/t/internationalization-localization/280");
    assert.dom(overlay()).doesNotExist();
  });
});

acceptance("Discourse Watermarking - disabled", function (needs) {
  needs.user({ watermark_payload: PAYLOAD });
  needs.settings({ user_fingerprint_enabled: false });

  test("does not render an overlay", async function (assert) {
    await visit("/t/internationalization-localization/280");
    assert.dom(overlay()).doesNotExist();
  });
});

acceptance("Discourse Watermarking - anonymous", function (needs) {
  needs.settings({
    user_fingerprint_enabled: true,
    user_fingerprint_strategy: "visual",
  });

  test("does not render an overlay for anonymous visitors", async function (assert) {
    await visit("/t/internationalization-localization/280");
    assert.dom(overlay()).doesNotExist();
  });
});
