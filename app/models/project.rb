class Project < ApplicationRecord
  has_many :issues, dependent: :destroy

  validates :name, presence: true, length: { maximum: 255 }
  validates :description, length: { maximum: 1000 }
end
