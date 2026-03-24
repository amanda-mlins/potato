# frozen_string_literal: true

require 'rails_helper'

# GitLab convention: single top-level RSpec.describe with the class under test
RSpec.describe Project do
  # ---------------------------------------------------------------
  # Associations — Shoulda::Matchers one-liners
  # ---------------------------------------------------------------
  describe 'associations' do
    it { is_expected.to have_many(:issues).dependent(:destroy) }
  end

  # ---------------------------------------------------------------
  # Validations — Shoulda::Matchers one-liners
  # ---------------------------------------------------------------
  describe 'validations' do
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_length_of(:name).is_at_most(255) }
    it { is_expected.to validate_length_of(:description).is_at_most(1000) }
  end

  # ---------------------------------------------------------------
  # Factory
  # ---------------------------------------------------------------
  describe 'factory' do
    it 'has a valid factory' do
      expect(build(:project)).to be_valid
    end
  end

  # ---------------------------------------------------------------
  # Custom behaviour
  # Use `context` for branching logic — GitLab guideline
  # ---------------------------------------------------------------
  describe 'validations (custom scenarios)' do
    context 'when name is blank' do
      subject(:project) { build(:project, name: '') }

      it 'is invalid' do
        expect(project).not_to be_valid
        expect(project.errors[:name]).to include("can't be blank")
      end
    end

    context 'when name exceeds 255 characters' do
      subject(:project) { build(:project, name: 'a' * 256) }

      it 'is invalid' do
        expect(project).not_to be_valid
        expect(project.errors[:name]).to include('is too long (maximum is 255 characters)')
      end
    end

    context 'when description exceeds 1000 characters' do
      subject(:project) { build(:project, description: 'a' * 1001) }

      it 'is invalid' do
        expect(project).not_to be_valid
      end
    end

    context 'when all attributes are valid' do
      subject(:project) { build(:project) }

      it 'is valid' do
        expect(project).to be_valid
      end
    end
  end

  # ---------------------------------------------------------------
  # Dependent destroy
  # ---------------------------------------------------------------
  describe 'dependent: :destroy' do
    let(:project) { create(:project) }
    let!(:issue) { create(:issue, project: project) }

    it 'destroys associated issues when deleted' do
      expect { project.destroy }.to change(Issue, :count).by(-1)
    end
  end
end
