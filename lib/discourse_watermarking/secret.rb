# frozen_string_literal: true

module DiscourseWatermarking
  module Secret
    SECRET_BYTES = 32

    def self.value
      SiteSetting.user_fingerprint_secret
    end

    def self.present?
      value.present?
    end

    def self.generate!
      SiteSetting.user_fingerprint_secret = SecureRandom.hex(SECRET_BYTES)
    end

    # Rotating the secret changes every user code and integrity tag at once,
    # invalidating all previously rendered watermarks. Payloads extracted from
    # screenshots taken before the rotation can no longer be decoded.
    def self.rotate!(acting_user)
      SiteSetting.set_and_log(
        :user_fingerprint_secret,
        SecureRandom.hex(SECRET_BYTES),
        acting_user,
      )
    end

    # A short, non-sensitive identifier for the current secret, so admins can
    # tell whether two sites/backups share the same key without exposing it.
    def self.fingerprint
      return nil if value.blank?
      Digest::SHA256.hexdigest("discourse-watermarking:fingerprint:#{value}")[0, 8]
    end
  end
end
