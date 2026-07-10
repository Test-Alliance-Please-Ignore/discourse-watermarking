# frozen_string_literal: true

class CreateDiscourseWatermarkingDecodeAudits < ActiveRecord::Migration[7.2]
  def change
    create_table :discourse_watermarking_decode_audits do |t|
      t.integer :acting_user_id, null: false
      t.integer :matched_user_id
      t.string :status, null: false, limit: 50
      t.string :input_digest, null: false, limit: 64
      t.timestamps
    end

    add_index :discourse_watermarking_decode_audits, :acting_user_id
    add_index :discourse_watermarking_decode_audits, :created_at
  end
end
