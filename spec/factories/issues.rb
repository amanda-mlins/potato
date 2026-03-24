# frozen_string_literal: true

FactoryBot.define do
  factory :issue do
    sequence(:title) { |n| "Issue #{n}" }
    description { "A test issue description" }
    status { :open }
    author_name { "Test Author" }

    # Associations — GitLab convention: use `association` for belongs_to
    association :project
  end
end
