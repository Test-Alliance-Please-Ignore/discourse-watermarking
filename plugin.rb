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

  # Generate a secret automatically the first time the plugin is enabled so
  # that a forgotten secret never results in a weak or empty key.
  on(:site_setting_changed) do |name, _old_value, new_value|
    if name == :user_fingerprint_enabled && new_value &&
         SiteSetting.user_fingerprint_secret.blank?
      DiscourseWatermarking::Secret.generate!
    end
  end
end
