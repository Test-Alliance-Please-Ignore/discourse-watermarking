# frozen_string_literal: true

module DiscourseWatermarking
  class DecodeAudit < ActiveRecord::Base
    self.table_name = "discourse_watermarking_decode_audits"

    belongs_to :acting_user, class_name: "User"
    belongs_to :matched_user, class_name: "User", optional: true

    validates :status, presence: true
    validates :input_digest, presence: true
  end
end

# == Schema Information
#
# Table name: discourse_watermarking_decode_audits
#
#  id              :bigint           not null, primary key
#  acting_user_id  :integer          not null
#  matched_user_id :integer
#  status          :string(50)       not null
#  input_digest    :string(64)       not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#
# Indexes
#
#  idx_on_acting_user_id_...  (acting_user_id)
#  idx_on_created_at_...      (created_at)
#
