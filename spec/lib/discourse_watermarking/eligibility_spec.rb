# frozen_string_literal: true

RSpec.describe DiscourseWatermarking::Eligibility do
  fab!(:user)
  fab!(:group)
  fab!(:category)

  before do
    SiteSetting.user_fingerprint_enabled = true
    SiteSetting.user_fingerprint_secret = SecureRandom.hex(32)
  end

  describe ".watermark_user?" do
    it "is false when the plugin is disabled" do
      SiteSetting.user_fingerprint_enabled = false
      expect(described_class.watermark_user?(user)).to eq(false)
    end

    it "is false when no secret is configured" do
      SiteSetting.user_fingerprint_secret = ""
      expect(described_class.watermark_user?(user)).to eq(false)
    end

    it "is false for anonymous visitors" do
      expect(described_class.watermark_user?(nil)).to eq(false)
    end

    it "is false for bots and the system user" do
      expect(described_class.watermark_user?(Discourse.system_user)).to eq(false)
      expect(described_class.watermark_user?(User.new(id: -100))).to eq(false)
    end

    it "is false for staged users" do
      user.update!(staged: true)
      expect(described_class.watermark_user?(user)).to eq(false)
    end

    it "is true for a regular user when no group restriction is configured" do
      expect(described_class.watermark_user?(user)).to eq(true)
    end

    it "respects the enabled groups restriction" do
      SiteSetting.user_fingerprint_enabled_groups = group.id.to_s
      expect(described_class.watermark_user?(user)).to eq(false)

      group.add(user)
      expect(described_class.watermark_user?(user.reload)).to eq(true)
    end
  end

  describe ".category_enabled?" do
    it "is true everywhere when no categories are configured" do
      expect(described_class.category_enabled?(category.id)).to eq(true)
      expect(described_class.category_enabled?(nil)).to eq(true)
    end

    it "only matches configured categories when restricted" do
      SiteSetting.user_fingerprint_enabled_categories = category.id.to_s

      expect(described_class.category_enabled?(category.id)).to eq(true)
      expect(described_class.category_enabled?(category.id + 1)).to eq(false)
      expect(described_class.category_enabled?(nil)).to eq(false)
    end
  end

  describe ".visual_enabled? and .text_enabled?" do
    it "maps the strategy setting to the active techniques" do
      SiteSetting.user_fingerprint_text_enabled = true

      SiteSetting.user_fingerprint_strategy = "visual"
      expect(described_class.visual_enabled?).to eq(true)
      expect(described_class.text_enabled?).to eq(false)

      SiteSetting.user_fingerprint_strategy = "text"
      expect(described_class.visual_enabled?).to eq(false)
      expect(described_class.text_enabled?).to eq(true)

      SiteSetting.user_fingerprint_strategy = "hybrid"
      expect(described_class.visual_enabled?).to eq(true)
      expect(described_class.text_enabled?).to eq(true)
    end

    it "keeps the text fingerprint off unless explicitly enabled" do
      SiteSetting.user_fingerprint_strategy = "hybrid"
      SiteSetting.user_fingerprint_text_enabled = false
      expect(described_class.text_enabled?).to eq(false)
    end
  end
end
