# frozen_string_literal: true

# Renders a single project with its nested issues.
#
# GET /projects/:id.json → { id, name, description, issues: [ … ] }

json.id          @project.id
json.name        @project.name
json.description @project.description
json.created_at  @project.created_at
json.updated_at  @project.updated_at
json.url         project_url(@project)

# Nested collection — each issue gets its own sub-object
json.issues @project.issues.recent do |issue|
  json.id          issue.id
  json.title       issue.title
  json.status      issue.status
  json.author_name issue.author_name
  json.created_at  issue.created_at
  json.url         issue_url(issue)

  # Nested labels inside each issue
  json.labels issue.labels do |label|
    json.id    label.id
    json.name  label.name
    json.color label.color
  end
end
