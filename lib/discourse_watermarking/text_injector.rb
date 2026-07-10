# frozen_string_literal: true

module DiscourseWatermarking
  # Server-side zero-width fingerprinting of rendered content.
  #
  # The client copy handler only covers leaks that go through a browser copy
  # event. Content fetched with an API key, a session-cookie scraper, or an
  # RSS reader never executes that JavaScript, so the fingerprint is also
  # injected here, at serialization time.
  #
  # Placement: one fingerprint is appended inside each closing paragraph so
  # that any copied or re-shared fragment of at least a paragraph carries it,
  # while text runs inside paragraphs stay contiguous (find-in-page and
  # selection behave normally). Injection is strictly presentation-layer —
  # stored raw and cooked never contain fingerprints, and Scrubber below
  # enforces that invariant against round-trips (quote, copy-paste).
  module TextInjector
    # Cooked HTML escapes user text, so a literal "</p>" can only be real
    # paragraph markup — never content inside <pre> or <code>.
    PARAGRAPH_CLOSE = "</p>"

    def self.fingerprint_for(user)
      return nil if !Eligibility.text_enabled?
      return nil if !Eligibility.watermark_user?(user)
      ZeroWidth.encode(Payload.tile_for(user.id))
    end

    # append_fallback adds one mark at the very end when the content has no
    # paragraphs at all (bare image or onebox posts). It must stay off for
    # XML feed bodies: trailing characters after the root element would make
    # the document malformed.
    def self.inject(cooked, user, category_id: nil, append_fallback: true)
      return cooked if cooked.blank?
      return cooked if !Eligibility.category_enabled?(category_id)

      fingerprint = fingerprint_for(user)
      return cooked if fingerprint.nil?

      marked = cooked.gsub(PARAGRAPH_CLOSE) { "#{fingerprint}#{PARAGRAPH_CLOSE}" }
      return marked if marked != cooked || !append_fallback
      marked + fingerprint
    end

    # Removes watermark fingerprints from user-submitted text before it is
    # stored. Copying marked content and pasting it into the composer (or
    # quoting it) would otherwise persist the previous viewer's fingerprint
    # inside the new post — and a later leak of that post could be attributed
    # to the wrong user. Only the exact marker+payload pattern is removed;
    # organic zero-width characters (emoji ZWJ sequences and the like) are
    # left alone.
    def self.scrub(raw)
      return raw if raw.blank?
      raw.gsub(ZeroWidth::FINGERPRINT_REGEX, "")
    end
  end
end
