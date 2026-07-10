# frozen_string_literal: true

RSpec.describe CurrentUserSerializer do
  fab!(:user)
  fab!(:group)
  fab!(:category)
  fab!(:topic) { Fabricate(:topic, category: category) }
  fab!(:post) { Fabricate(:post, topic: topic) }

  before do
    SiteSetting.user_fingerprint_enabled = true
    SiteSetting.user_fingerprint_secret = SecureRandom.hex(32)
  end

  def current_user_json(serialized_user)
    CurrentUserSerializer.new(serialized_user, scope: serialized_user.guardian, root: false).as_json
  end

  def topic_view_json(viewer)
    TopicViewSerializer.new(
      TopicView.new(topic.id, viewer),
      scope: viewer.guardian,
      root: false,
    ).as_json
  end

  describe "current user serializer" do
    it "includes an opaque payload for an eligible user" do
      json = current_user_json(user)

      expect(json[:watermark_payload]).to eq(
        DiscourseWatermarking::Payload.tile_hex_for(user.id),
      )
      expect(json[:watermark_payload]).not_to include(user.username)
      expect(json[:watermark_scoped_to_categories]).to eq(false)
    end

    it "omits the payload when the plugin is disabled" do
      SiteSetting.user_fingerprint_enabled = false
      expect(current_user_json(user)).not_to have_key(:watermark_payload)
    end

    it "omits the payload for users outside the enabled groups" do
      SiteSetting.user_fingerprint_enabled_groups = group.id.to_s
      expect(current_user_json(user)).not_to have_key(:watermark_payload)

      group.add(user)
      expect(current_user_json(user.reload)).to have_key(:watermark_payload)
    end

    it "signals category scoping without revealing categories" do
      SiteSetting.user_fingerprint_enabled_categories = category.id.to_s
      json = current_user_json(user)

      expect(json[:watermark_scoped_to_categories]).to eq(true)
      expect(json.values).not_to include([category.id])
    end
  end

  describe "topic view serializer" do
    it "flags topics in enabled categories" do
      SiteSetting.user_fingerprint_enabled_categories = category.id.to_s
      expect(topic_view_json(user)[:watermarking_enabled]).to eq(true)
    end

    it "flags all topics when unrestricted" do
      expect(topic_view_json(user)[:watermarking_enabled]).to eq(true)
    end

    it "does not flag topics outside enabled categories" do
      SiteSetting.user_fingerprint_enabled_categories = (category.id + 42).to_s
      expect(topic_view_json(user)[:watermarking_enabled]).to eq(false)
    end

    it "omits the flag entirely for ineligible users" do
      SiteSetting.user_fingerprint_enabled_groups = group.id.to_s
      expect(topic_view_json(user)).not_to have_key(:watermarking_enabled)
    end
  end
end
