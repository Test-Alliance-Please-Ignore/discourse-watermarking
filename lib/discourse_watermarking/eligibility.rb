# frozen_string_literal: true

module DiscourseWatermarking
  # Central scope rules: who gets watermarked, and where.
  module Eligibility
    def self.watermark_user?(user)
      return false if !SiteSetting.user_fingerprint_enabled
      return false if Secret.value.blank?
      return false if user.blank? || user.id < 1 || user.bot? || user.staged?

      group_ids = SiteSetting.user_fingerprint_enabled_groups_map
      group_ids.blank? || user.in_any_groups?(group_ids)
    end

    def self.scoped_to_categories?
      SiteSetting.user_fingerprint_enabled_categories_map.present?
    end

    def self.category_enabled?(category_id)
      category_ids = SiteSetting.user_fingerprint_enabled_categories_map
      return true if category_ids.blank?
      category_id.present? && category_ids.include?(category_id)
    end

    def self.visual_enabled?
      %w[visual hybrid].include?(SiteSetting.user_fingerprint_strategy)
    end

    def self.text_enabled?
      SiteSetting.user_fingerprint_text_enabled &&
        %w[text hybrid].include?(SiteSetting.user_fingerprint_strategy)
    end
  end
end
