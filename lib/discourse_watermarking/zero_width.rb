# frozen_string_literal: true

module DiscourseWatermarking
  # Zero-width text fingerprint codec.
  #
  # A fingerprint is MARKER followed by 32 characters from ALPHABET, each
  # encoding 2 bits (MSB first) of the 8-byte watermark tile. The client-side
  # encoder in assets/javascripts/discourse/lib/watermark.js must stay in sync
  # with this implementation.
  module ZeroWidth
    ZWSP = "\u200B" # ZERO WIDTH SPACE      => bits 00
    ZWNJ = "\u200C" # ZERO WIDTH NON-JOINER => bits 01
    ZWJ = "\u200D" #  ZERO WIDTH JOINER     => bits 10
    WJ = "\u2060" #   WORD JOINER           => bits 11

    ALPHABET = [ZWSP, ZWNJ, ZWJ, WJ].freeze

    # A four-character prefix marking the start of a fingerprint. Vanishingly
    # unlikely to occur in organic text.
    MARKER = "#{ZWJ}#{ZWNJ}#{ZWJ}#{WJ}"

    CHARS_PER_TILE = Payload::TILE_BYTES * 4

    FINGERPRINT_REGEX =
      /#{MARKER}([#{ZWSP}#{ZWNJ}#{ZWJ}#{WJ}]{#{CHARS_PER_TILE}})/

    ANY_ZERO_WIDTH = /[#{ZWSP}#{ZWNJ}#{ZWJ}#{WJ}\uFEFF]/

    def self.encode(bytes)
      chars = +""
      bytes.each_byte do |byte|
        3.downto(0) { |shift| chars << ALPHABET[(byte >> (shift * 2)) & 0b11] }
      end
      MARKER + chars
    end

    def self.decode(text)
      match = FINGERPRINT_REGEX.match(text)
      return nil if match.nil?

      match[1]
        .chars
        .each_slice(4)
        .map { |slice| slice.reduce(0) { |byte, char| (byte << 2) | ALPHABET.index(char) } }
        .pack("C*")
    end

    def self.present?(text)
      !!(text =~ ANY_ZERO_WIDTH)
    end

    def self.strip(text)
      text.gsub(ANY_ZERO_WIDTH, "")
    end
  end
end
