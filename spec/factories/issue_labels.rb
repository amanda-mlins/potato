# frozen_string_literal: true

FactoryBot.define do
  factory :issue_label do
    association :issue
    association :label
  end
end
