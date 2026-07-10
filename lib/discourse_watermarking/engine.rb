# frozen_string_literal: true

module DiscourseWatermarking
  class Engine < ::Rails::Engine
    engine_name PLUGIN_NAME
    isolate_namespace DiscourseWatermarking
  end
end
