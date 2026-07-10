# frozen_string_literal: true

RSpec.describe DiscourseWatermarking::Homoglyph do
  fab!(:user)

  before do
    SiteSetting.user_fingerprint_enabled = true
    SiteSetting.user_fingerprint_secret = SecureRandom.hex(32)
  end

  # A paragraph with plenty of substitutable Latin letters, repeated so a
  # full [sync + payload] period fits several times over.
  def long_cooked
    sentence =
      "<p>The alliance operations team coordinates capital escalations and " \
      "logistics across many systems every single campaign cycle.</p>"
    sentence * 16
  end

  def payload
    DiscourseWatermarking::Payload.payload_for(user.id)
  end

  describe ".embed_html and .decode_candidates" do
    it "round-trips the payload and resolves through the decoder" do
      marked = described_class.embed_html(long_cooked, payload)

      expect(marked).not_to eq(long_cooked)
      expect(described_class.decode_candidates(marked)).to include(payload)

      result = DiscourseWatermarking::Decoder.decode(marked)
      expect(result[:status]).to eq(:matched)
      expect(result[:user]).to eq(user)
    end

    it "leaves the visible text visually identical (only confusable swaps)" do
      marked = described_class.embed_html(long_cooked, payload)
      expect(described_class.strip(marked)).to eq(long_cooked)
    end

    it "recovers from a fragment that spans enough letters" do
      marked = described_class.embed_html(long_cooked, payload)
      fragment = marked[(marked.length / 3)..(2 * marked.length / 3)]
      expect(described_class.decode_candidates(fragment)).to include(payload)
    end
  end

  describe "exclusions" do
    it "never substitutes inside links, code, or mentions" do
      cooked =
        "<p>see <a href=\"https://example.com/place\">example place</a> and " \
        "<code>possible code</code> and <span class=\"mention\">@someone</span> ok</p>"
      marked = described_class.embed_html(cooked, payload)

      expect(marked).to include("https://example.com/place")
      expect(marked).to include(">example place<")
      expect(marked).to include("<code>possible code</code>")
      expect(marked).to include(">@someone<")
    end
  end

  describe ".strip" do
    it "restores confusables to their Latin originals" do
      marked = described_class.embed_html(long_cooked, payload)
      expect(described_class.present?(marked)).to eq(true)
      expect(described_class.strip(marked)).to eq(long_cooked)
    end
  end

  describe ".present?" do
    it "is false for plain Latin and true after embedding" do
      expect(described_class.present?("<p>plain latin text</p>")).to eq(false)
      expect(described_class.present?(described_class.embed_html(long_cooked, payload))).to eq(true)
    end
  end
end
