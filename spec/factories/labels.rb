# frozen_string_literal: true

FactoryBot.define do
  factory :label do
    sequence(:name) { |n| "Label #{n}" }
    color { "#ff0000" }

    # Traits for common label types — mirrors GitLab's label trait pattern
    trait :blue do
      color { "#0000ff" }
    end

    trait :green do
      color { "#00ff00" }
    end
  end
end
