import { withPluginApi } from "discourse/lib/plugin-api";
import {
  buildMaskUrl,
  encodeZeroWidth,
  isExcludedRoute,
  selectionAllowsFingerprint,
} from "discourse/plugins/discourse-watermarking/discourse/lib/watermark";

const MIN_COPY_LENGTH = 24;

export default {
  name: "discourse-watermarking",

  initialize(owner) {
    this._cleanup?.();
    this._cleanup = null;

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
    let destroyed = false;
    let overlay = null;

    const printMedia = visualEnabled ? window.matchMedia("print") : null;
    let printing = printMedia?.matches ?? false;

    const updatePaint = () => {
      if (!overlay) {
        return;
      }

      // Difference blending yields abs(backgroundBlue - amplitude), leaving
      // red and green unchanged. The default 8 per-mille gives two blue levels.
      const amplitude = printing
        ? 255
        : Math.max(
            1,
            Math.round(
              (siteSettings.user_fingerprint_visual_opacity / 1000) * 255
            )
          );

      // Dark Reader treats masked backgrounds as foreground artwork and
      // brightens this near-black paint. Protect the signal from its generated
      // stylesheet. Print colour must be assigned here too: a print stylesheet
      // cannot override an inline important declaration.
      overlay.style.setProperty(
        "background-color",
        `rgb(0 0 ${amplitude})`,
        "important"
      );
    };

    const beforePrint = () => {
      printing = true;
      updatePaint();
    };
    const afterPrint = () => {
      printing = false;
      updatePaint();
    };
    const printMediaChanged = (event) => {
      printing = event.matches;
      updatePaint();
    };

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
      overlay?.remove();
      overlay = null;
    };

    const renderOverlay = () => {
      if (!maskUrl) {
        return;
      }

      if (!overlay?.isConnected) {
        overlay = document.createElement("div");
        overlay.className = "d-view-layer";
        overlay.setAttribute("aria-hidden", "true");

        // Extension inversion rules filter the painted layer without changing
        // its computed background colour. Keep this numeric signal unfiltered
        // on screen and in print, even against important stylesheet rules.
        overlay.style.setProperty("filter", "none", "important");

        const density = siteSettings.user_fingerprint_visual_density;
        const tileSize = `${density * 8}px ${density * 8}px`;
        updatePaint();
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
    if (visualEnabled) {
      window.addEventListener("beforeprint", beforePrint);
      window.addEventListener("afterprint", afterPrint);
      printMedia.addEventListener("change", printMediaChanged);
    }

    this._cleanup = () => {
      destroyed = true;
      removeOverlay();
      if (textEnabled) {
        document.removeEventListener("copy", onCopy);
      }
      if (visualEnabled) {
        window.removeEventListener("beforeprint", beforePrint);
        window.removeEventListener("afterprint", afterPrint);
        printMedia.removeEventListener("change", printMediaChanged);
      }
    };

    withPluginApi((api) => {
      api.onPageChange(() => {
        if (destroyed) {
          return;
        }
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
