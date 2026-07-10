# frozen_string_literal: true

module DiscourseWatermarking
  class AdminWatermarkingController < ::Admin::StaffController
    requires_plugin PLUGIN_NAME

    MAX_INPUT_LENGTH = 20_000

    before_action :ensure_can_use_decoder, only: %i[status decode]
    before_action :ensure_admin, only: %i[rotate_secret]

    def status
      recent_audits =
        DecodeAudit
          .includes(:acting_user, :matched_user)
          .order(id: :desc)
          .limit(20)
          .map do |audit|
            {
              id: audit.id,
              acting_username: audit.acting_user&.username,
              matched_username: audit.matched_user&.username,
              status: audit.status,
              created_at: audit.created_at,
            }
          end

      render json: {
               plugin_version: DiscourseWatermarking::VERSION,
               enabled: SiteSetting.user_fingerprint_enabled,
               strategy: SiteSetting.user_fingerprint_strategy,
               visual_enabled: Eligibility.visual_enabled?,
               text_enabled: Eligibility.text_enabled?,
               visual_opacity: SiteSetting.user_fingerprint_visual_opacity,
               visual_density: SiteSetting.user_fingerprint_visual_density,
               secret_set: Secret.present?,
               secret_fingerprint: Secret.fingerprint,
               enabled_group_count: SiteSetting.user_fingerprint_enabled_groups_map.size,
               enabled_category_count: SiteSetting.user_fingerprint_enabled_categories_map.size,
               homoglyph_category_count: SiteSetting.user_fingerprint_homoglyph_categories_map.size,
               staff_only_decoder: SiteSetting.user_fingerprint_staff_only_decoder,
               recent_audits: recent_audits,
             }
    end

    def decode
      input = params.require(:input).to_s
      raise Discourse::InvalidParameters.new(:input) if input.length > MAX_INPUT_LENGTH
      raise Discourse::InvalidParameters.new(:input) if Secret.value.blank?

      RateLimiter.new(
        current_user,
        "watermark-decode",
        20,
        1.minute,
        apply_limit_to_staff: true,
      ).performed!

      result = Decoder.decode(input)

      DecodeAudit.create!(
        acting_user_id: current_user.id,
        matched_user_id: result[:user]&.id,
        status: result[:status].to_s,
        input_digest: Digest::SHA256.hexdigest(input),
      )

      render json: {
               status: result[:status],
               confidence: result[:confidence],
               version: result[:version],
               matched_count: result[:matches].size,
               users:
                 result[:matches].map { |user|
                   BasicUserSerializer.new(user, root: false).as_json
                 },
             }
    end

    def rotate_secret
      Secret.rotate!(current_user)
      render json: success_json.merge(secret_fingerprint: Secret.fingerprint)
    end

    private

    def ensure_can_use_decoder
      return if current_user.admin?

      if SiteSetting.user_fingerprint_staff_only_decoder || !current_user.moderator?
        raise Discourse::InvalidAccess.new
      end
    end
  end
end
