import { withPluginApi } from "discourse/lib/plugin-api";
import {
  buildMaskUrl,
  encodeZeroWidth,
  isExcludedRoute,
  selectionAllowsFingerprint,
} from "discourse/plugins/discourse-watermarking/discourse/lib/watermark";

const OVERLAY_ID = "discourse-watermark-overlay";
const MIN_COPY_LENGTH = 24;

export default {
  name: "discourse-watermarking",

  initialize(owner) {
    const siteSettings = owner.lookup("service:site-settings");
    const currentUser = owner.lookup("service:current-user");

    if (!siteSettings.user_fingerprint_enabled) {
      return;
    }

    const payload = currentUser?.watermark_payload;
    if (!payload) {
      return;
    }

    const strategy = siteSettings.user_fingerprint_strategy;
    const visualEnabled = strategy === "visual" || strategy === "hybrid";
    const textEnabled =
      siteSettings.user_fingerprint_text_enabled &&
      (strategy === "text" || strategy === "hybrid");

    if (!visualEnabled && !textEnabled) {
      return;
    }

    const maskUrl = visualEnabled ? buildMaskUrl(payload) : null;
    const zeroWidthSuffix = textEnabled ? encodeZeroWidth(payload) : null;
    const scopedToCategories = !!currentUser.watermark_scoped_to_categories;

    // Whether watermarking applies to the page currently being displayed.
    // Shared by the overlay and the copy handler.
    let activeHere = false;

    const routerService = owner.lookup("service:router");

    const overlayActive = () => {
      const routeName = routerService.currentRouteName;
      const url = routerService.currentURL;

      if (isExcludedRoute(routeName, url)) {
        return false;
      }

      if (routeName?.startsWith("topic.")) {
        const topic = owner.lookup("controller:topic")?.model;
        if (topic && topic.watermarking_enabled === false) {
          return false;
        }
        return true;
      }

      // Outside topics there is no per-category server flag, so when the
      // admin restricted watermarking to categories only topic views are
      // marked.
      return !scopedToCategories;
    };

    const removeOverlay = () => {
      document.getElementById(OVERLAY_ID)?.remove();
    };

    const renderOverlay = () => {
      if (!maskUrl) {
        return;
      }

      let overlay = document.getElementById(OVERLAY_ID);
      if (!overlay) {
        overlay = document.createElement("div");
        overlay.id = OVERLAY_ID;
        overlay.className = "discourse-watermark-overlay";
        overlay.setAttribute("aria-hidden", "true");

        const density = siteSettings.user_fingerprint_visual_density;
        const tileSize = `${density * 8}px ${density * 8}px`;
        overlay.style.opacity = (
          siteSettings.user_fingerprint_visual_opacity / 1000
        ).toString();
        overlay.style.maskImage = maskUrl;
        overlay.style.maskSize = tileSize;

        document.body.appendChild(overlay);
      }
    };

    const onCopy = (event) => {
      if (!activeHere || !zeroWidthSuffix || event.defaultPrevented) {
        return;
      }
      if (!event.clipboardData) {
        return;
      }

      const selection = document.getSelection();
      if (!selectionAllowsFingerprint(selection)) {
        return;
      }

      const text = selection.toString();
      if (text.length < MIN_COPY_LENGTH) {
        return;
      }

      event.clipboardData.setData("text/plain", text + zeroWidthSuffix);

      // Preserve the rich-text flavor that the default copy would have
      // produced, fingerprinted the same way.
      const fragment = document.createElement("div");
      fragment.appendChild(selection.getRangeAt(0).cloneContents());
      event.clipboardData.setData(
        "text/html",
        fragment.innerHTML + zeroWidthSuffix
      );

      event.preventDefault();
    };

    if (textEnabled) {
      document.addEventListener("copy", onCopy);
    }

    this._cleanup = () => {
      removeOverlay();
      if (textEnabled) {
        document.removeEventListener("copy", onCopy);
      }
    };

    withPluginApi((api) => {
      api.onPageChange(() => {
        activeHere = overlayActive();

        if (visualEnabled && activeHere) {
          renderOverlay();
        } else {
          removeOverlay();
        }
      });
    });
  },

  teardown() {
    this._cleanup?.();
    this._cleanup = null;
  },
};
