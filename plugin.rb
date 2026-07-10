# frozen_string_literal: true

# name: discourse-watermarking
# about: Per-user forensic watermarking of rendered forum content to help identify the source of leaked screenshots and copied text.
# version: 1.0.0
# authors: Discourse Watermarking Contributors
# url: https://github.com/discourse/discourse-watermarking
# required_version: 2.7.0

enabled_site_setting :user_fingerprint_enabled

register_asset "stylesheets/common/discourse-watermarking.scss"
register_asset "stylesheets/admin/discourse-watermarking-admin.scss", :admin

register_svg_icon "fingerprint"
register_svg_icon "arrows-rotate"

module ::DiscourseWatermarking
  PLUGIN_NAME = "discourse-watermarking"
  VERSION = "1.0.0"
end

require_relative "lib/discourse_watermarking/engine"

after_initialize do
  require_relative "lib/discourse_watermarking/secret"
  require_relative "lib/discourse_watermarking/payload"
  require_relative "lib/discourse_watermarking/zero_width"
  require_relative "lib/discourse_watermarking/eligibility"
  require_relative "lib/discourse_watermarking/decoder"
  require_relative "lib/discourse_watermarking/text_injector"

  # route: /admin/plugins/discourse-watermarking
  add_admin_route("discourse_watermarking.title", "discourse-watermarking", use_new_show_route: true)

  # The opaque watermark payload for the logged-in user. It contains no
  # directly identifying information; it can only be resolved back to a user
  # with the server-side secret via the admin decoder.
  add_to_serializer(
    :current_user,
    :watermark_payload,
    include_condition: -> { DiscourseWatermarking::Eligibility.watermark_user?(object) },
  ) { DiscourseWatermarking::Payload.tile_hex_for(object.id) }

  # Tells the client whether watermarking is limited to specific categories,
  # without revealing which ones. When true, the client only renders the
  # overlay on topics whose topic view is flagged below.
  add_to_serializer(
    :current_user,
    :watermark_scoped_to_categories,
    include_condition: -> { DiscourseWatermarking::Eligibility.watermark_user?(object) },
  ) { DiscourseWatermarking::Eligibility.scoped_to_categories? }

  add_to_serializer(
    :topic_view,
    :watermarking_enabled,
    include_condition: -> { DiscourseWatermarking::Eligibility.watermark_user?(scope.user) },
  ) { DiscourseWatermarking::Eligibility.category_enabled?(object.topic&.category_id) }

  # Server-side text fingerprinting: content fetched without executing the
  # client JavaScript (API keys, scrapers, RSS readers) would otherwise be
  # completely unmarked. The wrapper preserves all core cooked logic
  # (hidden-post placeholders, localization) by calling super.
  module ::DiscourseWatermarking::CookedFingerprint
    def cooked
      DiscourseWatermarking::TextInjector.inject(
        super,
        scope&.user,
        category_id: object.topic&.category_id,
      )
    end
  end

  reloadable_patch do
    ::BasicPostSerializer.prepend(::DiscourseWatermarking::CookedFingerprint)
  end

  # RSS/Atom feeds render post HTML through view templates, not serializers,
  # so the fingerprint is added to the response body instead. Every CDATA
  # section gets one — invisible to feed readers either way. When
  # watermarking is scoped to categories, only single-topic feeds can be
  # attributed to a category, so list feeds are left unmarked rather than
  # marking content outside the configured scope.
  module ::DiscourseWatermarking::FeedFingerprint
    def self.prepended(base)
      base.after_action :discourse_watermarking_mark_feed
    end

    def discourse_watermarking_mark_feed
      return if !request.format&.rss?
      return if response.body.blank?

      category_id =
        if DiscourseWatermarking::Eligibility.scoped_to_categories?
          topic = instance_variable_get(:@topic_view)&.topic
          return if topic.nil?
          topic.category_id
        end

      marked =
        DiscourseWatermarking::TextInjector.inject(
          response.body,
          current_user,
          category_id: category_id,
          append_fallback: false,
        )
      response.body = marked if marked != response.body
    end
  end

  reloadable_patch { ::ApplicationController.prepend(::DiscourseWatermarking::FeedFingerprint) }

  # Enforce the "stored content never carries a fingerprint" invariant:
  # text copied from a marked page and pasted (or quoted) into the composer
  # would otherwise persist the copier's fingerprint inside the new post,
  # and a later leak of that post could be attributed to the wrong user.
  add_model_callback(:post, :before_save) do
    self.raw = DiscourseWatermarking::TextInjector.scrub(raw) if raw_changed?
  end

  # Generate a secret automatically the first time the plugin is enabled so
  # that a forgotten secret never results in a weak or empty key.
  on(:site_setting_changed) do |name, _old_value, new_value|
    if name == :user_fingerprint_enabled && new_value &&
         SiteSetting.user_fingerprint_secret.blank?
      DiscourseWatermarking::Secret.generate!
    end
  end
end
