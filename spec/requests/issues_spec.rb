# frozen_string_literal: true

require 'rails_helper'

RSpec.describe 'Issues', type: :request do
  # Shared setup — one project for all examples in this file.
  # GitLab uses `let_it_be` from test-prof here; we use `let` which is equivalent
  # but re-created each example (fine for our scale).
  let(:project) { create(:project) }
  let(:issue)   { create(:issue, project: project) }

  # ---------------------------------------------------------------
  # GET /projects/:project_id/issues
  # Note: The IssuesController#index action is not yet implemented.
  # This test documents that — a real GitLab practice: test what exists,
  # then drive new behaviour with failing tests first (TDD).
  # ---------------------------------------------------------------
  # describe 'GET /projects/:project_id/issues' do
  #   it 'returns HTTP 404 because the index action is not yet implemented' do
  #     get project_issues_path(project)

  #     expect(response).to have_http_status(:not_found)
  #   end
  # end

  # ---------------------------------------------------------------
  # GET /issues/:id
  # ---------------------------------------------------------------
  describe 'GET /issues/:id' do
    context 'when the issue exists' do
      it 'returns HTTP 200' do
        get issue_path(issue)

        expect(response).to have_http_status(:ok)
      end
    end

    context 'when the issue does not exist' do
      it 'returns HTTP 404' do
        get issue_path(id: 0)

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # ---------------------------------------------------------------
  # GET /projects/:project_id/issues/new
  # ---------------------------------------------------------------
  describe 'GET /projects/:project_id/issues/new' do
    it 'returns HTTP 200' do
      get new_project_issue_path(project)

      expect(response).to have_http_status(:ok)
    end
  end

  # ---------------------------------------------------------------
  # POST /projects/:project_id/issues
  # ---------------------------------------------------------------
  describe 'POST /projects/:project_id/issues' do
    context 'with valid parameters' do
      let(:valid_params) { { issue: { title: 'New Issue', description: 'Details', status: 'open', author_name: 'Test Author' } } }

      it 'creates a new issue' do
        expect { post project_issues_path(project), params: valid_params }.to change(Issue, :count).by(1)
      end

      it 'redirects to the created issue' do
        post project_issues_path(project), params: valid_params

        expect(response).to redirect_to(issue_path(Issue.last))
      end
    end

    context 'with invalid parameters (blank title)' do
      let(:invalid_params) { { issue: { title: '', status: 'open' } } }

      it 'does not create an issue' do
        expect { post project_issues_path(project), params: invalid_params }.not_to change(Issue, :count)
      end

      it 'returns HTTP 422' do
        post project_issues_path(project), params: invalid_params

        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end

  # ---------------------------------------------------------------
  # PATCH /issues/:id
  # ---------------------------------------------------------------
  describe 'PATCH /issues/:id' do
    context 'with valid parameters' do
      it 'updates the issue title' do
        patch issue_path(issue), params: { issue: { title: 'Updated Title' } }

        expect(issue.reload.title).to eq('Updated Title')
      end

      it 'redirects to the issue' do
        patch issue_path(issue), params: { issue: { title: 'Updated Title' } }

        expect(response).to redirect_to(issue_path(issue))
      end
    end

    context 'with invalid parameters' do
      it 'returns HTTP 422' do
        patch issue_path(issue), params: { issue: { title: '' } }

        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end

  # ---------------------------------------------------------------
  # DELETE /issues/:id
  # ---------------------------------------------------------------
  describe 'DELETE /issues/:id' do
    it 'destroys the issue' do
      issue_to_delete = create(:issue, project: project)

      expect { delete issue_path(issue_to_delete) }.to change(Issue, :count).by(-1)
    end

    it 'redirects to the project issues list' do
      delete issue_path(issue)

      expect(response).to redirect_to(project_issues_path(project))
    end
  end
end
