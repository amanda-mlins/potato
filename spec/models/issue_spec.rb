# frozen_string_literal: true

require 'rails_helper'

RSpec.describe Issue do
  # ---------------------------------------------------------------
  # Associations
  # ---------------------------------------------------------------
  describe 'associations' do
    it { is_expected.to belong_to(:project) }
    it { is_expected.to have_many(:issue_labels).dependent(:destroy) }
    it { is_expected.to have_many(:labels).through(:issue_labels) }
  end

  # ---------------------------------------------------------------
  # Validations
  # ---------------------------------------------------------------
  describe 'validations' do
    it { is_expected.to validate_presence_of(:title) }
    it { is_expected.to validate_presence_of(:author_name) }
    it { is_expected.to validate_length_of(:title).is_at_most(255) }
    it { is_expected.to validate_length_of(:description).is_at_most(1000) }
  end

  # ---------------------------------------------------------------
  # Factory
  # ---------------------------------------------------------------
  describe 'factory' do
    it 'has a valid factory' do
      expect(build(:issue)).to be_valid
    end
  end

  # ---------------------------------------------------------------
  # Enum
  # GitLab tests enum behaviour, not enum constant values
  # ---------------------------------------------------------------
  describe 'status enum' do
    # Use build for the default check (no DB needed)
    subject(:issue) { build(:issue) }

    it 'defaults to open' do
      expect(issue.status).to eq('open')
    end

    # Use create for bang methods that persist
    context 'when set to in_progress' do
      let(:persisted_issue) { create(:issue) }

      before { persisted_issue.in_progress! }

      it 'is in_progress' do
        expect(persisted_issue).to be_in_progress
      end
    end

    context 'when set to closed' do
      let(:persisted_issue) { create(:issue) }

      before { persisted_issue.closed! }

      it 'is closed' do
        expect(persisted_issue).to be_closed
      end
    end

    it 'raises on an invalid status value' do
      expect { issue.status = :unknown }.to raise_error(ArgumentError)
    end
  end

  # ---------------------------------------------------------------
  # Scopes
  # ---------------------------------------------------------------
  describe 'scopes' do
    let(:project) { create(:project) }

    describe '.recent' do
      it 'orders issues by created_at descending' do
        older = create(:issue, project: project, created_at: 2.days.ago)
        newer = create(:issue, project: project, created_at: 1.day.ago)

        expect(described_class.recent).to eq([ newer, older ])
      end
    end

    describe '.by_status' do
      let!(:open_issue) { create(:issue, project: project, status: :open) }
      let!(:closed_issue) { create(:issue, project: project, status: :closed) }

      it 'returns only issues matching the given status' do
        expect(described_class.by_status(:open)).to contain_exactly(open_issue)
        expect(described_class.by_status(:closed)).to contain_exactly(closed_issue)
      end
    end

    describe '.with_labels' do
      let!(:issue) { create(:issue, project: project) }
      let(:label) { create(:label) }

      before { create(:issue_label, issue: issue, label: label) }

      it 'eager loads labels to avoid N+1 queries' do
        result = described_class.with_labels.find(issue.id)

        # Assert the association is already loaded (no extra query)
        expect(result.association(:labels)).to be_loaded
      end
    end
  end

  # ---------------------------------------------------------------
  # Custom validation scenarios
  # ---------------------------------------------------------------
  describe 'validations (custom scenarios)' do
    context 'when title is blank' do
      subject(:issue) { build(:issue, title: '') }

      it 'is invalid' do
        expect(issue).not_to be_valid
        expect(issue.errors[:title]).to include("can't be blank")
      end
    end

    context 'when title exceeds 255 characters' do
      subject(:issue) { build(:issue, title: 'a' * 256) }

      it 'is invalid' do
        expect(issue).not_to be_valid
      end
    end
  end
end
