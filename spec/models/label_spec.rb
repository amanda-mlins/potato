# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Label do
  # ---------------------------------------------------------------
  # Associations
  # ---------------------------------------------------------------
  describe 'associations' do
    it { is_expected.to have_many(:issue_labels).dependent(:destroy) }
    it { is_expected.to have_many(:issues).through(:issue_labels) }
  end

  # ---------------------------------------------------------------
  # Validations
  # ---------------------------------------------------------------
  describe 'validations' do
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_length_of(:name).is_at_most(255) }
    it { is_expected.to validate_presence_of(:color) }
  end

  # ---------------------------------------------------------------
  # Factory
  # ---------------------------------------------------------------
  describe 'factory' do
    it 'has a valid factory' do
      expect(build(:label)).to be_valid
    end

    it 'has a valid :blue trait' do
      expect(build(:label, :blue)).to be_valid
    end

    it 'has a valid :green trait' do
      expect(build(:label, :green)).to be_valid
    end
  end

  # ---------------------------------------------------------------
  # Color validation (hex format)
  # Table-based test — mirrors GitLab's preferred parameterized style
  # ---------------------------------------------------------------
  describe 'color format validation' do
    using RSpec::Parameterized::TableSyntax rescue nil # optional gem, graceful skip

    valid_colors   = %w[#ff0000 #00FF00 #1a2B3c #000000 #ffffff]
    invalid_colors = %w[red ff0000 #ggg #12345 #1234567 #]

    context 'with valid hex colors' do
      valid_colors.each do |color|
        it "accepts #{color}" do
          expect(build(:label, color: color)).to be_valid
        end
      end
    end

    context 'with invalid colors' do
      invalid_colors.each do |color|
        it "rejects '#{color}'" do
          label = build(:label, color: color)

          expect(label).not_to be_valid
          expect(label.errors[:color]).to include('must be a valid hex color code')
        end
      end
    end
  end
end
