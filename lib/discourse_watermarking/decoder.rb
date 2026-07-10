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

    def self.decode(input)
      candidates = extract_payloads(input.to_s)
      return result(:invalid_input) if candidates.empty?

      unsupported_version = nil

      candidates.each do |payload|
        version = Payload.version_of(payload)
        if version != Payload::VERSION
          unsupported_version ||= version
          next
        end
        next if !Payload.verify(payload)

        matches = find_users_with_code(Payload.extract_user_code(payload))

        case matches.size
        when 0
          return result(:no_match)
        when 1
          return result(:matched, user: matches.first, confidence: "high")
        else
          # A 32-bit user code collision — astronomically unlikely, but
          # report honestly instead of picking one.
          return(
            result(:matched, user: matches.first, matches: matches, confidence: "ambiguous")
          )
        end
      end

      if unsupported_version && candidates.size == 1
        result(:unsupported_version, version: unsupported_version)
      else
        result(:invalid_signature)
      end
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
