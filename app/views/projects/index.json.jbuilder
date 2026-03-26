# frozen_string_literal: true

# Renders an array of projects.
# Called automatically by respond_to format.json when no explicit render is given.
#
# GET /projects.json → [ { id, name, description, created_at }, … ]

json.array! @projects do |project|
  json.id          project.id
  json.name        project.name
  json.description project.description
  json.created_at  project.created_at
  json.updated_at  project.updated_at

  # Include the URL so API clients can follow links without hardcoding paths
  json.url project_url(project)
end
