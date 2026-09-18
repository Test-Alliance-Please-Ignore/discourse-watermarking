import { visit } from "@ember/test-helpers";
import { test } from "qunit";
import { acceptance } from "discourse/tests/helpers/qunit-helpers";

const PAYLOAD = "c51fa2b3c4d5e6f7";

function overlay() {
  return document.querySelector(".d-view-layer");
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
    assert.false(element.hasAttribute("id"), "the layer needs no DOM ID");

    const style = element.style;
    assert.true(
      style.maskImage.includes("data:image/svg+xml"),
      "pattern is applied as a mask"
    );
    assert.strictEqual(
      getComputedStyle(element).backgroundColor,
      "rgb(0, 0, 5)",
      "blue-channel amplitude follows the opacity setting (20‰ of 255 ≈ 5)"
    );
    assert.strictEqual(
      style.maskSize,
      "256px 256px",
      "tile size follows density"
    );
  });

  test("preserves the signal against a Dark Reader inline override", async function (assert) {
    await visit("/t/internationalization-localization/280");

    const element = overlay();
    const override = document.createElement("style");
    override.textContent = `[data-darkreader-inline-bgcolor] {
      background-color: var(--darkreader-inline-bgcolor) !important;
    }`;
    document.head.appendChild(override);
    element.setAttribute("data-darkreader-inline-bgcolor", "");
    element.style.setProperty(
      "--darkreader-inline-bgcolor",
      "rgb(231, 229, 226)"
    );

    try {
      assert.strictEqual(
        getComputedStyle(element).backgroundColor,
        "rgb(0, 0, 5)",
        "the rendered colour retains the configured blue amplitude"
      );
      assert.strictEqual(getComputedStyle(element).mixBlendMode, "difference");
    } finally {
      override.remove();
      element.removeAttribute("data-darkreader-inline-bgcolor");
      element.style.removeProperty("--darkreader-inline-bgcolor");
    }
  });

  test("restores screen paint after repeated or cancelled printing", async function (assert) {
    await visit("/t/internationalization-localization/280");

    try {
      for (let i = 0; i < 2; i++) {
        window.dispatchEvent(new Event("beforeprint"));
        assert.strictEqual(
          getComputedStyle(overlay()).backgroundColor,
          "rgb(0, 0, 255)",
          "printing uses the blue veil"
        );
        window.dispatchEvent(new Event("afterprint"));
        assert.strictEqual(
          getComputedStyle(overlay()).backgroundColor,
          "rgb(0, 0, 5)",
          "closing the print dialog restores the screen amplitude"
        );
      }
    } finally {
      window.dispatchEvent(new Event("afterprint"));
    }
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
