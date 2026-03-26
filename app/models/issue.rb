class Issue < ApplicationRecord
  belongs_to :project
  has_many :issue_labels, dependent: :destroy
  has_many :labels, through: :issue_labels

  enum :status, { open: 0, in_progress: 1, closed: 2 }
  # Title: presence, length, and reusable custom profanity validator
  validates :title, presence: true, length: { maximum: 255 }, no_profanity: true
  validates :author_name, presence: true
  validates :description, length: { maximum: 1000 }
  validates :status, presence: true

  # Example of an inline custom validation method (per-record rules)
  validate :author_name_cannot_contain_digits

  scope :recent,      -> { order(created_at: :desc) }
  scope :by_status,   ->(status) { where(status: status) }
  scope :with_labels, -> { includes(:labels) }
end

private

def author_name_cannot_contain_digits
  return if author_name.blank?

  if author_name.match?(/\d/)
    errors.add(:author_name, "cannot contain numbers")
  end
end
