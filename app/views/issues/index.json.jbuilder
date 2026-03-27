json.pagination do
  json.current_page @pagy.page
  json.total_pages  @pagy.last
  json.total_count  @pagy.count
  json.per_page     @pagy.limit
  json.next_page    @pagy.next
  json.prev_page    @pagy.prev
end

json.issues @issues do |issue|
  json.id          issue.id
  json.title       issue.title
  json.status      issue.status
  json.author_name issue.author_name
  json.description issue.description
  json.created_at  issue.created_at
  json.labels      issue.labels.map(&:name)
  json.url         issue_url(issue)
end
