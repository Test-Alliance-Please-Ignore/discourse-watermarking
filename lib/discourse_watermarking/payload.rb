# frozen_string_literal: true

module DiscourseWatermarking
  # Binary watermark payload, version 1.
  #
  # Tile layout (64 bits, rendered row-major into an 8x8 grid):
  #
  #   byte 0      SYNC_BYTE (0xC5) — asymmetric alignment/orientation row
  #   byte 1      version (high nibble) | reserved (low nibble, zero)
  #   bytes 2..5  user code — first 4 bytes of HMAC-SHA256(secret, user id)
  #   bytes 6..7  integrity tag — first 2 bytes of HMAC-SHA256(secret, bytes 1..5)
  #
  # The user code is an opaque, deterministic pseudonym: it cannot be reversed
  # to a user id without the secret, and it changes when the secret rotates.
  # The integrity tag makes payloads unforgeable without the secret, so the
  # decoder can reject modified or fabricated inputs.
  module Payload
    VERSION = 1
    SYNC_BYTE = 0xC5
    PAYLOAD_BYTES = 7
    TILE_BYTES = 8
    USER_CODE_BYTES = 4
    TAG_BYTES = 2

    def self.user_code(user_id, secret: Secret.value)
      hmac(secret, "user:v#{VERSION}:#{user_id}")[0, USER_CODE_BYTES]
    end

    def self.payload_for(user_id, secret: Secret.value)
      body = [VERSION << 4].pack("C") + user_code(user_id, secret: secret)
      body + tag(body, secret: secret)
    end

    def self.tile_for(user_id, secret: Secret.value)
      [SYNC_BYTE].pack("C") + payload_for(user_id, secret: secret)
    end

    def self.tile_hex_for(user_id, secret: Secret.value)
      tile_for(user_id, secret: secret).unpack1("H*")
    end

    def self.version_of(payload)
      payload.getbyte(0) >> 4
    end

    def self.extract_user_code(payload)
      payload.byteslice(1, USER_CODE_BYTES)
    end

    def self.verify(payload, secret: Secret.value)
      return false if payload.nil? || payload.bytesize != PAYLOAD_BYTES
      body = payload.byteslice(0, PAYLOAD_BYTES - TAG_BYTES)
      ActiveSupport::SecurityUtils.fixed_length_secure_compare(
        payload.byteslice(PAYLOAD_BYTES - TAG_BYTES, TAG_BYTES),
        tag(body, secret: secret),
      )
    end

    def self.tag(body, secret:)
      hmac(secret, "tag:v#{VERSION}:#{body}")[0, TAG_BYTES]
    end

    def self.hmac(secret, message)
      raise Discourse::SiteSettingMissing, "user_fingerprint_secret" if secret.blank?
      OpenSSL::HMAC.digest("SHA256", secret, "discourse-watermarking:#{message}")
    end
  end
end
