# frozen_string_literal: true

RSpec.describe "Server-side text fingerprinting" do
  fab!(:user)
  fab!(:topic)
  fab!(:post) { Fabricate(:post, topic: topic, raw: "sensitive fleet doctrine information here") }

  let(:fingerprint_regex) { DiscourseWatermarking::ZeroWidth::FINGERPRINT_REGEX }

  before do
    SiteSetting.user_fingerprint_enabled = true
    SiteSetting.user_fingerprint_secret = SecureRandom.hex(32)
    SiteSetting.user_fingerprint_strategy = "hybrid"
    SiteSetting.user_fingerprint_text_enabled = true
  end

  describe "topic JSON" do
    it "marks cooked content for an eligible signed-in user and resolves back to them" do
      sign_in(user)
      get "/t/#{topic.slug}/#{topic.id}.json"
      expect(response.status).to eq(200)

      cooked = response.parsed_body["post_stream"]["posts"].first["cooked"]
      expect(cooked).to match(fingerprint_regex)

      result = DiscourseWatermarking::Decoder.decode(cooked)
      expect(result[:status]).to eq(:matched)
      expect(result[:user]).to eq(user)
    end

    it "serves clean content to anonymous visitors" do
      get "/t/#{topic.slug}/#{topic.id}.json"
      expect(response.status).to eq(200)

      cooked = response.parsed_body["post_stream"]["posts"].first["cooked"]
      expect(cooked).not_to match(fingerprint_regex)
    end

    it "serves clean content when the plugin is disabled" do
      SiteSetting.user_fingerprint_enabled = false
      sign_in(user)
      get "/t/#{topic.slug}/#{topic.id}.json"

      cooked = response.parsed_body["post_stream"]["posts"].first["cooked"]
      expect(cooked).not_to match(fingerprint_regex)
    end

    it "does not mark the raw markdown used for editing" do
      sign_in(user)
      get "/posts/#{post.id}.json"
      expect(response.status).to eq(200)
      expect(response.parsed_body["raw"]).not_to match(fingerprint_regex)
    end

    it "respects category scoping" do
      other_category = Fabricate(:category)
      SiteSetting.user_fingerprint_enabled_categories = other_category.id.to_s

      sign_in(user)
      get "/t/#{topic.slug}/#{topic.id}.json"

      cooked = response.parsed_body["post_stream"]["posts"].first["cooked"]
      expect(cooked).not_to match(fingerprint_regex)
    end
  end

  describe "topic RSS" do
    it "marks the feed for an eligible signed-in user and resolves back to them" do
      sign_in(user)
      get "/t/#{topic.slug}/#{topic.id}.rss"
      expect(response.status).to eq(200)

      expect(response.body).to match(fingerprint_regex)

      result = DiscourseWatermarking::Decoder.decode(response.body)
      expect(result[:status]).to eq(:matched)
      expect(result[:user]).to eq(user)
    end

    it "keeps the feed well-formed XML" do
      sign_in(user)
      get "/t/#{topic.slug}/#{topic.id}.rss"

      expect { Nokogiri.XML(response.body) { |cfg| cfg.strict } }.not_to raise_error
    end

    it "serves a clean feed when watermarking is scoped to other categories" do
      other_category = Fabricate(:category)
      SiteSetting.user_fingerprint_enabled_categories = other_category.id.to_s

      sign_in(user)
      get "/t/#{topic.slug}/#{topic.id}.rss"
      expect(response.body).not_to match(fingerprint_regex)
    end
  end

  describe "stored-content invariant" do
    it "scrubs pasted fingerprints from new posts on save" do
      foreign_fingerprint =
        DiscourseWatermarking::ZeroWidth.encode(
          DiscourseWatermarking::Payload.tile_for(Fabricate(:user).id),
        )

      pasted =
        Fabricate(
          :post,
          topic: topic,
          raw: "quoting a marked post: original words#{foreign_fingerprint} and my reply",
        )

      expect(pasted.reload.raw).to eq("quoting a marked post: original words and my reply")
    end

    it "keeps emoji ZWJ sequences intact on save" do
      raw = "family emoji \u{1F468}\u200D\u{1F469}\u200D\u{1F467} stays whole in this post"
      saved = Fabricate(:post, topic: topic, raw: raw)
      expect(saved.reload.raw).to eq(raw)
    end
  end
end
