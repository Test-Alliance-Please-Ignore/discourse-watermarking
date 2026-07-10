# frozen_string_literal: true

RSpec.describe DiscourseWatermarking::TextInjector do
  fab!(:user)

  before do
    SiteSetting.user_fingerprint_enabled = true
    SiteSetting.user_fingerprint_secret = SecureRandom.hex(32)
    SiteSetting.user_fingerprint_strategy = "hybrid"
    SiteSetting.user_fingerprint_text_enabled = true
  end

  def fingerprint
    DiscourseWatermarking::ZeroWidth.encode(DiscourseWatermarking::Payload.tile_for(user.id))
  end

  describe ".inject" do
    it "appends a fingerprint inside every paragraph" do
      cooked = "<p>first</p>\n<p>second</p>"
      marked = described_class.inject(cooked, user)

      expect(marked.scan(DiscourseWatermarking::ZeroWidth::FINGERPRINT_REGEX).size).to eq(2)
      expect(marked).to eq("<p>first#{fingerprint}</p>\n<p>second#{fingerprint}</p>")
    end

    it "resolves back to the injecting user through the decoder" do
      marked = described_class.inject("<p>leaked content</p>", user)

      result = DiscourseWatermarking::Decoder.decode(marked)
      expect(result[:status]).to eq(:matched)
      expect(result[:user]).to eq(user)
    end

    it "does not touch paragraph markup rendered as text inside code blocks" do
      cooked = "<p>real</p><pre><code>&lt;p&gt;fake&lt;/p&gt;</code></pre>"
      marked = described_class.inject(cooked, user)

      expect(marked).to include("<pre><code>&lt;p&gt;fake&lt;/p&gt;</code></pre>")
      expect(marked.scan(DiscourseWatermarking::ZeroWidth::FINGERPRINT_REGEX).size).to eq(1)
    end

    it "appends one mark to paragraph-less content by default" do
      marked = described_class.inject("<img src='/x.png'>", user)
      expect(marked).to eq("<img src='/x.png'>#{fingerprint}")
    end

    it "leaves paragraph-less content alone when the fallback is disabled" do
      cooked = "<img src='/x.png'>"
      expect(described_class.inject(cooked, user, append_fallback: false)).to eq(cooked)
    end

    it "returns the input unchanged for anonymous viewers" do
      cooked = "<p>hello</p>"
      expect(described_class.inject(cooked, nil)).to eq(cooked)
    end

    it "returns the input unchanged when the strategy is visual-only" do
      SiteSetting.user_fingerprint_strategy = "visual"
      cooked = "<p>hello</p>"
      expect(described_class.inject(cooked, user)).to eq(cooked)
    end

    it "returns the input unchanged when the text channel is disabled" do
      SiteSetting.user_fingerprint_text_enabled = false
      cooked = "<p>hello</p>"
      expect(described_class.inject(cooked, user)).to eq(cooked)
    end

    it "respects category scoping" do
      enabled = Fabricate(:category)
      other = Fabricate(:category)
      SiteSetting.user_fingerprint_enabled_categories = enabled.id.to_s

      cooked = "<p>hello</p>"
      expect(described_class.inject(cooked, user, category_id: enabled.id)).not_to eq(cooked)
      expect(described_class.inject(cooked, user, category_id: other.id)).to eq(cooked)
      expect(described_class.inject(cooked, user, category_id: nil)).to eq(cooked)
    end

    it "respects group scoping" do
      group = Fabricate(:group)
      SiteSetting.user_fingerprint_enabled_groups = group.id.to_s

      cooked = "<p>hello</p>"
      expect(described_class.inject(cooked, user)).to eq(cooked)

      group.add(user)
      expect(described_class.inject(cooked, user.reload)).not_to eq(cooked)
    end
  end

  describe ".scrub" do
    it "removes fingerprint patterns" do
      text = "pasted #{fingerprint}content#{fingerprint}"
      expect(described_class.scrub(text)).to eq("pasted content")
    end

    it "preserves emoji ZWJ sequences and organic zero-width characters" do
      family = "\u{1F468}\u200D\u{1F469}\u200D\u{1F467}"
      text = "a#{family}b\u200Bc"
      expect(described_class.scrub(text)).to eq(text)
    end

    it "handles blank input" do
      expect(described_class.scrub(nil)).to be_nil
      expect(described_class.scrub("")).to eq("")
    end
  end
end
