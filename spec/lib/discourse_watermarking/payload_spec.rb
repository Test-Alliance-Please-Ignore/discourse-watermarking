# frozen_string_literal: true

RSpec.describe DiscourseWatermarking::Payload do
  let(:secret) { "0" * 64 }

  before do
    SiteSetting.user_fingerprint_enabled = true
    SiteSetting.user_fingerprint_secret = secret
  end

  describe ".tile_hex_for" do
    it "is deterministic for the same user and secret" do
      expect(described_class.tile_hex_for(42)).to eq(described_class.tile_hex_for(42))
    end

    it "differs between users" do
      expect(described_class.tile_hex_for(1)).not_to eq(described_class.tile_hex_for(2))
    end

    it "changes when the secret rotates" do
      before_rotation = described_class.tile_hex_for(42)
      SiteSetting.user_fingerprint_secret = "1" * 64
      expect(described_class.tile_hex_for(42)).not_to eq(before_rotation)
    end

    it "starts with the sync byte and is 64 bits long" do
      hex = described_class.tile_hex_for(42)
      expect(hex.length).to eq(16)
      expect(hex[0, 2].to_i(16)).to eq(described_class::SYNC_BYTE)
    end

    it "contains no direct user identifier" do
      user_id = 1_234_567
      hex = described_class.tile_hex_for(user_id)
      expect(hex).not_to include(user_id.to_s)
      expect(hex).not_to include(user_id.to_s(16))
    end
  end

  describe ".verify" do
    it "accepts an untampered payload" do
      expect(described_class.verify(described_class.payload_for(42))).to eq(true)
    end

    it "rejects a payload with a flipped user code bit" do
      payload = described_class.payload_for(42).bytes
      payload[2] ^= 0x01
      expect(described_class.verify(payload.pack("C*"))).to eq(false)
    end

    it "rejects a payload with a modified tag" do
      payload = described_class.payload_for(42).bytes
      payload[6] ^= 0xFF
      expect(described_class.verify(payload.pack("C*"))).to eq(false)
    end

    it "rejects payloads generated under a different secret" do
      forged = described_class.payload_for(42, secret: "attacker-controlled")
      expect(described_class.verify(forged)).to eq(false)
    end

    it "rejects payloads of the wrong length" do
      expect(described_class.verify("short")).to eq(false)
      expect(described_class.verify(nil)).to eq(false)
    end
  end

  it "raises when no secret is configured" do
    SiteSetting.user_fingerprint_secret = ""
    expect { described_class.payload_for(42) }.to raise_error(Discourse::SiteSettingMissing)
  end
end
