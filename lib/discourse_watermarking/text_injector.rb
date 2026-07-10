# frozen_string_literal: true

module DiscourseWatermarking
  # Server-side zero-width fingerprinting of rendered content.
  #
  # The client copy handler only covers leaks that go through a browser copy
  # event. Content fetched with an API key, a session-cookie scraper, or an
  # RSS reader never executes that JavaScript, so the fingerprint is also
  # injected here, at serialization time.
  #
  # Placement: a fingerprint is appended inside every block-level element so
  # that any copied or re-shared fragment spanning one block carries it, while
  # text runs inside a block stay contiguous (find-in-page and selection
  # behave normally). Injection is strictly presentation-layer — stored raw
  # and cooked never contain fingerprints, and scrub below enforces that
  # invariant against round-trips (quote, copy-paste).
  #
  # A second, opt-in text channel — homoglyph substitution, gated per
  # category — is applied through this module too; see Homoglyph.
  module TextInjector
    # Cooked HTML escapes user text, so these literal close tags can only be
    # real block markup — never content inside <pre> or <code>. Marking every
    # block (not just paragraphs) means a short excerpt — one list item, a
    # heading, a table cell — still carries a full fingerprint.
    BLOCK_CLOSES = %w[
      </p> </li> </blockquote> </h1> </h2> </h3> </h4> </h5> </h6> </td>
    ].freeze

    def self.fingerprint_for(user)
      return nil if !Eligibility.text_enabled?
      return nil if !Eligibility.watermark_user?(user)
      ZeroWidth.encode(Payload.tile_for(user.id))
    end

    # append_fallback adds one mark at the very end when the content has no
    # block elements at all (bare image or onebox posts). It must stay off for
    # XML feed bodies: trailing characters after the root element would make
    # the document malformed.
    def self.inject(cooked, user, category_id: nil, append_fallback: true)
      return cooked if cooked.blank?
      return cooked if !Eligibility.category_enabled?(category_id)

      fingerprint = fingerprint_for(user)
      return cooked if fingerprint.nil?

      marked = cooked
      BLOCK_CLOSES.each { |tag| marked = marked.gsub(tag) { "#{fingerprint}#{tag}" } }
      return marked if marked != cooked || !append_fallback
      marked + fingerprint
    end

    # Applies the per-category homoglyph channel. Independent of the
    # visual/text strategy — gated solely by the homoglyph category list and
    # the shared user-eligibility rules.
    def self.homoglyph(cooked, user, category_id: nil)
      return cooked if cooked.blank?
      return cooked if !Eligibility.watermark_user?(user)
      return cooked if !Eligibility.homoglyph_category?(category_id)

      Homoglyph.embed_html(cooked, Payload.payload_for(user.id))
    end

    # Removes watermark fingerprints from user-submitted text before it is
    # stored. Copying marked content and pasting it into the composer (or
    # quoting it) would otherwise persist the previous viewer's fingerprint
    # inside the new post — and a later leak of that post could be attributed
    # to the wrong user.
    #
    # Zero-width: only the exact marker+payload pattern is removed, so organic
    # zero-width characters (emoji ZWJ sequences) survive. Homoglyph: only
    # scrubbed when the text actually contains a fingerprint that verifies
    # against the current secret, so a genuinely Cyrillic or Greek post (which
    # will never produce an HMAC-valid frame) is never Latinized.
    def self.scrub(raw)
      return raw if raw.blank?
      scrubbed = raw.gsub(ZeroWidth::FINGERPRINT_REGEX, "")
      scrub_homoglyphs(scrubbed)
    end

    def self.scrub_homoglyphs(text)
      return text if !Homoglyph.present?(text)
      return text if Homoglyph.decode_candidates(text).none? { |payload| Payload.verify(payload) }
      Homoglyph.strip(text)
    end
  end
end
