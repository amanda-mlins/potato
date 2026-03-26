# frozen_string_literal: true

# Renders a single issue with its labels.
#
# GET /issues/:id.json → { id, title, status, author_name, labels: [ … ] }

json.id          @issue.id
json.title       @issue.title
json.description @issue.description
json.status      @issue.status
json.author_name @issue.author_name
json.created_at  @issue.created_at
json.updated_at  @issue.updated_at
json.url         issue_url(@issue)

# Nested labels
json.labels @issue.labels do |label|
  json.id    label.id
  json.name  label.name
  json.color label.color
end

# Parent project summary
json.project do
  json.id   @issue.project.id
  json.name @issue.project.name
  json.url  project_url(@issue.project)
end
