# frozen_string_literal: true

RSpec.describe DiscourseWatermarking::AdminWatermarkingController do
  fab!(:admin)
  fab!(:moderator)
  fab!(:user)

  before do
    SiteSetting.user_fingerprint_enabled = true
    SiteSetting.user_fingerprint_secret = SecureRandom.hex(32)
  end

  describe "#decode" do
    let(:tile_hex) { DiscourseWatermarking::Payload.tile_hex_for(user.id) }

    it "is not accessible anonymously" do
      post "/admin/plugins/discourse-watermarking/decode.json", params: { input: tile_hex }
      expect(response.status).to eq(404)
    end

    it "is not accessible to regular users" do
      sign_in(user)
      post "/admin/plugins/discourse-watermarking/decode.json", params: { input: tile_hex }
      expect(response.status).to eq(404)
    end

    it "rejects moderators while the decoder is admin-only" do
      sign_in(moderator)
      post "/admin/plugins/discourse-watermarking/decode.json", params: { input: tile_hex }
      expect(response.status).to eq(403)
    end

    it "allows moderators when the decoder is opened to staff" do
      SiteSetting.user_fingerprint_staff_only_decoder = false
      sign_in(moderator)

      post "/admin/plugins/discourse-watermarking/decode.json", params: { input: tile_hex }

      expect(response.status).to eq(200)
      expect(response.parsed_body["status"]).to eq("matched")
    end

    it "resolves a valid payload to the originating user" do
      sign_in(admin)

      post "/admin/plugins/discourse-watermarking/decode.json", params: { input: tile_hex }

      expect(response.status).to eq(200)
      expect(response.parsed_body["status"]).to eq("matched")
      expect(response.parsed_body["confidence"]).to eq("high")
      expect(response.parsed_body["users"].map { |u| u["id"] }).to contain_exactly(user.id)
    end

    it "rejects forged payloads" do
      sign_in(admin)
      forged =
        DiscourseWatermarking::Payload.payload_for(user.id, secret: "attacker").unpack1("H*")

      post "/admin/plugins/discourse-watermarking/decode.json", params: { input: forged }

      expect(response.status).to eq(200)
      expect(response.parsed_body["status"]).to eq("invalid_signature")
      expect(response.parsed_body["users"]).to be_empty
    end

    it "records an audit entry for every decode" do
      sign_in(admin)

      expect {
        post "/admin/plugins/discourse-watermarking/decode.json", params: { input: tile_hex }
      }.to change { DiscourseWatermarking::DecodeAudit.count }.by(1)

      audit = DiscourseWatermarking::DecodeAudit.last
      expect(audit.acting_user_id).to eq(admin.id)
      expect(audit.matched_user_id).to eq(user.id)
      expect(audit.status).to eq("matched")
      expect(audit.input_digest).to eq(Digest::SHA256.hexdigest(tile_hex))
    end

    it "rejects oversized input" do
      sign_in(admin)
      post "/admin/plugins/discourse-watermarking/decode.json",
           params: {
             input: "a" * 20_001,
           }
      expect(response.status).to eq(400)
    end

    it "is unavailable when the plugin is disabled" do
      SiteSetting.user_fingerprint_enabled = false
      sign_in(admin)
      post "/admin/plugins/discourse-watermarking/decode.json", params: { input: tile_hex }
      expect(response.status).to eq(404)
    end

    it "is rate limited" do
      sign_in(admin)
      RateLimiter.enable

      20.times do
        post "/admin/plugins/discourse-watermarking/decode.json", params: { input: tile_hex }
        expect(response.status).to eq(200)
      end

      post "/admin/plugins/discourse-watermarking/decode.json", params: { input: tile_hex }
      expect(response.status).to eq(429)
    end
  end

  describe "#rotate_secret" do
    it "requires an administrator" do
      SiteSetting.user_fingerprint_staff_only_decoder = false
      sign_in(moderator)
      post "/admin/plugins/discourse-watermarking/rotate-secret.json"
      expect(response.status).to eq(403)
    end

    it "replaces the secret and invalidates old payloads" do
      sign_in(admin)
      old_secret = SiteSetting.user_fingerprint_secret
      old_tile = DiscourseWatermarking::Payload.tile_hex_for(user.id)

      post "/admin/plugins/discourse-watermarking/rotate-secret.json"

      expect(response.status).to eq(200)
      expect(SiteSetting.user_fingerprint_secret).not_to eq(old_secret)
      expect(DiscourseWatermarking::Decoder.decode(old_tile)[:status]).to eq(:invalid_signature)
    end
  end

  describe "#status" do
    it "returns diagnostics for admins" do
      sign_in(admin)

      get "/admin/plugins/discourse-watermarking/status.json"

      expect(response.status).to eq(200)
      body = response.parsed_body
      expect(body["plugin_version"]).to eq(DiscourseWatermarking::VERSION)
      expect(body["enabled"]).to eq(true)
      expect(body["secret_set"]).to eq(true)
      expect(body["secret_fingerprint"]).to match(/\A\h{8}\z/)
      expect(body["secret_fingerprint"]).not_to eq(SiteSetting.user_fingerprint_secret)
    end

    it "is denied to moderators while the decoder is admin-only" do
      sign_in(moderator)
      get "/admin/plugins/discourse-watermarking/status.json"
      expect(response.status).to eq(403)
    end
  end
end
