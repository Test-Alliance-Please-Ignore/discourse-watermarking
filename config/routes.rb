# frozen_string_literal: true

DiscourseWatermarking::Engine.routes.draw do
  get "/status" => "admin_watermarking#status"
  post "/decode" => "admin_watermarking#decode"
  post "/rotate-secret" => "admin_watermarking#rotate_secret"
end

Discourse::Application.routes.draw do
  mount DiscourseWatermarking::Engine,
        at: "/admin/plugins/discourse-watermarking",
        constraints: StaffConstraint.new
end
