# frozen_string_literal: true

module DiscourseWatermarking
  # Homoglyph text fingerprint codec — a second, strip-resistant text channel.
  #
  # A handful of Latin letters are swapped for visually identical characters
  # from other Unicode blocks (Cyrillic / Greek). The substitution rides
  # inside real letters, so it survives sanitizers that strip zero-width
  # characters but do not normalize confusables — a different failure mode
  # from the zero-width channel, which is the point of running both.
  #
  # A repeating [sync header + payload] bit pattern is written across the
  # substitutable letters, so any excerpt spanning enough letters holds a
  # full copy. Recovery slides a window looking for the sync header and reads
  # the payload that follows; the decoder's HMAC tag then confirms it.
  #
  # Only Latin letters are ever substituted (never existing non-Latin text),
  # so legitimately Cyrillic or Greek posts are left untouched. As a
  # consequence the channel only recovers cleanly from predominantly
  # Latin-script content — which is documented, and acceptable for a targeted
  # per-category channel.
  module Homoglyph
    # Latin -> visually identical confusable (Cyrillic / Greek). Kept to
    # letters whose confusables render identically in common forum fonts.
    MAP = {
      "a" => "а", "c" => "с", "e" => "е", "i" => "і", "j" => "ј",
      "o" => "о", "p" => "р", "s" => "ѕ", "x" => "х", "y" => "у",
      "A" => "А", "B" => "В", "C" => "С", "E" => "Е", "H" => "Н",
      "K" => "К", "M" => "М", "O" => "О", "P" => "Р", "T" => "Т",
      "X" => "Х"
    }.freeze

    LATIN_TO_HG = MAP
    HG_TO_LATIN = MAP.invert.freeze
    HG_PATTERN = Regexp.union(HG_TO_LATIN.keys).freeze

    # A fixed sync header precedes each payload so the decoder, which sees an
    # unframed bitstream, can find frame boundaries by sliding.
    SYNC = [1, 0, 1, 1, 0, 0, 1, 0].freeze
    PAYLOAD_BITS = Payload::PAYLOAD_BYTES * 8
    PERIOD = SYNC.length + PAYLOAD_BITS
    MAX_CANDIDATES = 64

    # Cooked HTML nodes whose text must never be altered: substituting a
    # letter inside a link, code, mention, or onebox would break the link
    # target, the code, or the reference.
    EXCLUDED_TAGS = %w[a code pre kbd samp script style].freeze
    EXCLUDED_CLASSES = %w[mention hashtag hashtag-cooked onebox].freeze

    def self.period_bits(payload)
      SYNC + payload.bytes.flat_map { |byte| 7.downto(0).map { |shift| (byte >> shift) & 1 } }
    end

    # Substitutes Latin letters in the text nodes of `cooked` (outside
    # excluded ancestors) to carry the payload. Returns the modified HTML.
    def self.embed_html(cooked, payload)
      return cooked if cooked.blank?

      pattern = period_bits(payload)
      doc = Nokogiri::HTML5.fragment(cooked)
      slot = 0

      doc.traverse do |node|
        next unless node.text?
        next if excluded_ancestor?(node)
        text = node.content
        next unless text.match?(/[A-Za-z]/)

        buffer = +""
        text.each_char do |char|
          if LATIN_TO_HG.key?(char)
            buffer << (pattern[slot % pattern.length] == 1 ? LATIN_TO_HG[char] : char)
            slot += 1
          else
            buffer << char
          end
        end
        node.content = buffer
      end

      slot.positive? ? doc.to_html : cooked
    end

    def self.excluded_ancestor?(node)
      current = node.parent
      while current&.element?
        return true if EXCLUDED_TAGS.include?(current.name)
        classes = current["class"].to_s.split
        return true if (classes & EXCLUDED_CLASSES).any?
        current = current.parent
      end
      false
    end

    def self.present?(text)
      text.present? && text.match?(HG_PATTERN)
    end

    # Tags and HTML entities contain Latin letters (the "p" in <p>, the
    # "amp" in &amp;) that were never substitution slots, so they must be
    # removed before reading the bitstream — otherwise the extra bits shift
    # the alignment and hide the payload. Copied rendered text has neither,
    # but a leaker pasting raw HTML source would.
    HTML_NOISE = /<[^>]+>|&[a-zA-Z]+;|&#\d+;/

    # Every distinct payload found at a sync-aligned position. False syncs are
    # harmless: the decoder rejects any candidate whose HMAC tag fails.
    def self.decode_candidates(text)
      return [] if text.blank?

      bits = []
      text.gsub(HTML_NOISE, " ").each_char do |char|
        if HG_TO_LATIN.key?(char)
          bits << 1
        elsif LATIN_TO_HG.key?(char)
          bits << 0
        end
      end
      return [] if bits.length < PERIOD

      seen = {}
      candidates = []
      (0..bits.length - PERIOD).each do |i|
        next unless bits[i, SYNC.length] == SYNC
        frame = bits[i + SYNC.length, PAYLOAD_BITS]
        bytes = frame.each_slice(8).map { |octet| octet.reduce(0) { |acc, b| (acc << 1) | b } }.pack("C*")
        next if seen[bytes]
        seen[bytes] = true
        candidates << bytes
        break if candidates.length >= MAX_CANDIDATES
      end
      candidates
    end

    def self.strip(text)
      return text if text.blank?
      text.gsub(HG_PATTERN) { |char| HG_TO_LATIN[char] }
    end
  end
end
