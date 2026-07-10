# frozen_string_literal: true

module DiscourseWatermarking
  # Resolves a recovered watermark back to the originating user.
  #
  # Accepted inputs:
  #   * 16 hex characters (full 64-bit tile, including the sync byte)
  #   * 14 hex characters (56-bit payload without the sync byte)
  #   * 64 or 56 binary digits (optionally whitespace-separated)
  #   * arbitrary text containing a zero-width fingerprint
  #   * the raw output of tools/extract_watermark.py — every candidate is
  #     tried and the one with a valid signature wins
  #
  # Resolution never requires session logs: the user code is recomputed from
  # the current secret for every real user and compared in constant time.
  module Decoder
    HEX_REGEX = /\A\h{14}(\h{2})?\z/
    BITS_REGEX = /\A[01]{56}([01]{8})?\z/
    MAX_CANDIDATES = 64

    # Screenshot extraction routinely delivers payloads with a few flipped
    # bits, so after trying every candidate verbatim the decoder retries
    # small Hamming-distance variants. Acceptance requires the 16-bit tag
    # AND a 32-bit user-code match against a real user, so even ~10k trials
    # keep the false-accept probability around 2^-48 per trial — the
    # correction is statistically free.
    ONE_FLIP_CANDIDATES = 32
    TWO_FLIP_CANDIDATES = 8

    # Byte 0 of a v1 payload is fixed (version nibble 1, reserved nibble 0),
    # so bit corrections only make sense in the user code and tag.
    FLIPPABLE_BITS = (8...(Payload::PAYLOAD_BYTES * 8)).to_a

    def self.decode(input)
      candidates = extract_payloads(input.to_s)
      return result(:invalid_input) if candidates.empty?

      unsupported_version = nil
      usable =
        candidates.filter_map do |payload|
          version = Payload.version_of(payload)
          if version != Payload::VERSION
            unsupported_version ||= version
            nil
          else
            canonicalize(payload)
          end
        end
      usable.uniq!

      if usable.empty?
        return result(:unsupported_version, version: unsupported_version) if unsupported_version
        return result(:invalid_signature)
      end

      tried = {}
      verified_without_user = false

      each_variant(usable) do |payload, confidence|
        next if tried[payload]
        tried[payload] = true
        next if !Payload.verify(payload)

        matches = find_users_with_code(Payload.extract_user_code(payload))

        case matches.size
        when 0
          # A verified tag whose user is gone (or was derived under another
          # secret): remember it, but keep searching — with bit-flip
          # expansion a later variant can still be the real payload.
          verified_without_user = true
        when 1
          return result(:matched, user: matches.first, confidence: confidence)
        else
          # A 32-bit user code collision — astronomically unlikely, but
          # report honestly instead of picking one.
          return(
            result(:matched, user: matches.first, matches: matches, confidence: "ambiguous")
          )
        end
      end

      verified_without_user ? result(:no_match) : result(:invalid_signature)
    end

    # Yields payload variants in decreasing order of trustworthiness:
    # every candidate verbatim, then 1-bit flips, then 2-bit flips of the
    # best-ranked candidates (extraction output is ordered best first).
    def self.each_variant(payloads)
      payloads.each { |payload| yield payload, "high" }

      payloads
        .first(ONE_FLIP_CANDIDATES)
        .each do |payload|
          FLIPPABLE_BITS.each do |bit|
            yield flip_bit(payload, bit), "corrected (1 flipped bit)"
          end
        end

      payloads
        .first(TWO_FLIP_CANDIDATES)
        .each do |payload|
          FLIPPABLE_BITS.combination(2) do |bit_a, bit_b|
            yield flip_bit(flip_bit(payload, bit_a), bit_b), "corrected (2 flipped bits)"
          end
        end
    end

    # v1 payloads always carry version nibble 1 and reserved nibble 0, so a
    # corrupted byte 0 can be repaired outright instead of spending flip
    # budget on it.
    def self.canonicalize(payload)
      canonical = payload.dup
      canonical.setbyte(0, Payload::VERSION << 4)
      canonical
    end

    def self.flip_bit(payload, bit)
      flipped = payload.dup
      flipped.setbyte(bit / 8, flipped.getbyte(bit / 8) ^ (0x80 >> (bit % 8)))
      flipped
    end

    def self.extract_payloads(input)
      zero_width = ZeroWidth.decode(input)
      return [strip_sync(zero_width)].compact if zero_width

      candidates = []
      input.each_line do |line|
        chunks = [line.gsub(/[\s:,-]/, "").downcase]
        chunks.concat(line.split.map(&:downcase))
        chunks.each do |chunk|
          payload =
            if chunk.match?(BITS_REGEX)
              strip_sync([chunk].pack("B*"))
            elsif chunk.match?(HEX_REGEX)
              strip_sync([chunk].pack("H*"))
            end
          candidates << payload if payload
        end
      end
      candidates.uniq.first(MAX_CANDIDATES)
    end

    def self.strip_sync(bytes)
      return bytes if bytes.bytesize == Payload::PAYLOAD_BYTES
      return nil if bytes.bytesize != Payload::TILE_BYTES
      # Tolerate a corrupted sync byte: the integrity tag is authoritative.
      bytes.byteslice(1, Payload::PAYLOAD_BYTES)
    end

    def self.find_users_with_code(code)
      secret = Secret.value
      matches = []
      User.real.where("users.id > 0").find_in_batches(batch_size: 2500) do |batch|
        batch.each do |user|
          if ActiveSupport::SecurityUtils.fixed_length_secure_compare(
               Payload.user_code(user.id, secret: secret),
               code,
             )
            matches << user
          end
        end
      end
      matches
    end

    def self.result(status, user: nil, matches: nil, confidence: nil, version: nil)
      {
        status: status,
        user: user,
        matches: matches || (user ? [user] : []),
        confidence: confidence,
        version: version,
      }
    end
  end
end
