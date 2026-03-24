# frozen_string_literal: true

require 'rails_helper'

# GitLab uses request specs (not controller specs) for HTTP-level testing.
# Request specs exercise the full routing → controller → response stack.
RSpec.describe 'Projects', type: :request do
  # Use `let` for shared setup — lazy, created only when referenced
  let(:project) { create(:project) }

  # ---------------------------------------------------------------
  # GET /projects
  # ---------------------------------------------------------------
  describe 'GET /projects' do
    it 'returns HTTP 200' do
      get projects_path

      expect(response).to have_http_status(:ok)
    end

    it 'includes projects in the response body' do
      create(:project, name: 'My Visible Project')

      get projects_path

      expect(response.body).to include('My Visible Project')
    end
  end

  # ---------------------------------------------------------------
  # GET /projects/:id
  # ---------------------------------------------------------------
  describe 'GET /projects/:id' do
    context 'when the project exists' do
      it 'returns HTTP 200' do
        get project_path(project)

        expect(response).to have_http_status(:ok)
      end
    end

    context 'when the project does not exist' do
      it 'returns HTTP 404' do
        get project_path(id: 0)

        expect(response).to have_http_status(:not_found)
      end
    end
  end

  # ---------------------------------------------------------------
  # GET /projects/new
  # ---------------------------------------------------------------
  describe 'GET /projects/new' do
    it 'returns HTTP 200' do
      get new_project_path

      expect(response).to have_http_status(:ok)
    end
  end

  # ---------------------------------------------------------------
  # POST /projects
  # ---------------------------------------------------------------
  describe 'POST /projects' do
    context 'with valid parameters' do
      let(:valid_params) { { project: { name: 'My Project', description: 'A description' } } }

      it 'creates a new project' do
        expect { post projects_path, params: valid_params }.to change(Project, :count).by(1)
      end

      it 'redirects to the new project' do
        post projects_path, params: valid_params

        expect(response).to redirect_to(project_path(Project.last))
      end
    end

    context 'with invalid parameters (blank name)' do
      let(:invalid_params) { { project: { name: '' } } }

      it 'does not create a project' do
        expect { post projects_path, params: invalid_params }.not_to change(Project, :count)
      end

      it 'returns HTTP 422 (unprocessable entity)' do
        post projects_path, params: invalid_params

        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end

  # ---------------------------------------------------------------
  # PATCH /projects/:id
  # ---------------------------------------------------------------
  describe 'PATCH /projects/:id' do
    context 'with valid parameters' do
      it 'updates the project' do
        patch project_path(project), params: { project: { name: 'Updated Name' } }

        expect(project.reload.name).to eq('Updated Name')
      end

      it 'redirects to the project' do
        patch project_path(project), params: { project: { name: 'Updated Name' } }

        expect(response).to redirect_to(project_path(project))
      end
    end

    context 'with invalid parameters' do
      it 'returns HTTP 422' do
        patch project_path(project), params: { project: { name: '' } }

        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end

  # ---------------------------------------------------------------
  # DELETE /projects/:id
  # ---------------------------------------------------------------
  describe 'DELETE /projects/:id' do
    it 'destroys the project' do
      project_to_delete = create(:project)

      expect { delete project_path(project_to_delete) }.to change(Project, :count).by(-1)
    end

    it 'redirects to projects index' do
      delete project_path(project)

      expect(response).to redirect_to(projects_path)
    end
  end
end
