# Rails Interview Guide

## Built while developing a GitLab-style Issue Tracker

> A living document of Rails concepts covered during mentorship sessions.

---

## Table of Contents

1. [Project Setup & PostgreSQL](#1-project-setup--postgresql)
2. [Database Migrations](#2-database-migrations)
3. [ActiveRecord Models & Associations](#3-activerecord-models--associations)
4. [Validations](#4-validations)
5. [Enums](#5-enums)
6. [Creating & Updating Records](#6-creating--updating-records)
7. [Zeitwerk — The Rails Autoloader](#7-zeitwerk--the-rails-autoloader)
8. [Routing & Nested Resources](#8-routing--nested-resources)
9. [Controllers](#9-controllers)
10. [Views, Partials & Form Helpers](#10-views-partials--form-helpers)
11. [String Helpers — humanize, pluralize & Inflector](#11-string-helpers--humanize-pluralize--inflector)
12. [Initializers](#12-initializers)
13. [Scopes](#13-scopes)
14. [N+1 Queries & Eager Loading](#14-n1-queries--eager-loading)
15. [SQL Joins](#15-sql-joins)

---

## 1. Project Setup & PostgreSQL

### Switching from SQLite to PostgreSQL

Replace in `Gemfile`:

```ruby
# Before
gem "sqlite3", ">= 2.1"

# After
gem "pg", "~> 1.5"
```

Update `config/database.yml` to use the `postgresql` adapter with ENV-based credentials:

```yaml
default: &default
  adapter: postgresql
  encoding: unicode
  pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
  host: <%= ENV.fetch("DB_HOST") { "localhost" } %>
  username: <%= ENV.fetch("DB_USERNAME") { "postgres" } %>
  password: <%= ENV.fetch("DB_PASSWORD") { "" } %>
```

> **Key insight**: Use `ENV.fetch("KEY") { default }` over `ENV["KEY"]`. The block form is safer — it won't silently return `nil` if the variable is missing (though `fetch` without a block would raise `KeyError`). Using a default makes local dev zero-config.

### macOS / Homebrew PostgreSQL gotchas

- Homebrew installs PostgreSQL with your **macOS username** as the superuser, not `postgres`
- You must create the `postgres` role manually:

  ```bash
  createuser -s postgres   # -s = superuser
  ```

- Start the server as a background service:

  ```bash
  brew services start postgresql@16
  ```

- Key commands:

  ```bash
  rails db:create    # CREATE DATABASE for dev + test
  rails db:migrate   # run pending migrations
  rails db:schema:load  # faster alternative to replaying all migrations on a fresh DB
  ```

---

## 2. Database Migrations

### Generating migrations

```bash
rails generate migration CreateProjects name:string description:text
rails generate migration CreateIssues title:string description:text status:integer project:references
rails generate migration CreateLabels name:string color:string
rails generate migration CreateIssueLabels issue:references label:references
```

### What `references` does automatically

`project:references` is Rails shorthand that generates **three things** at once:

1. A `project_id bigint` column
2. A **database index** on `project_id` — critical for JOIN performance
3. A **foreign key constraint** — referential integrity enforced at DB level

### `null: false` — Defence in depth

Always enforce constraints at **both** the DB level and application level:

```ruby
# DB layer — migration
change_column_null :projects, :name, false

# App layer — model
validates :name, presence: true
```

If someone bypasses the app (rake task, rails console, direct SQL), the DB constraint is your last line of defence.

### `schema.rb` — The source of truth

- Auto-generated from the current DB state after each migration
- A new developer runs `rails db:schema:load` to get the exact same DB without replaying all migrations
- Old migrations can rot (they reference old model code); `schema.rb` never does
- **Always commit `schema.rb` to version control**

### Migration status

```bash
rails db:migrate:status   # shows up/down status for every migration
```

---

## 3. ActiveRecord Models & Associations

### Our data model

```
projects ──< issues >──< issue_labels >──< labels
```

### Association types used

```ruby
# One-to-many
class Project < ApplicationRecord
  has_many :issues, dependent: :destroy
end

class Issue < ApplicationRecord
  belongs_to :project   # adds project_id FK, validates presence by default (Rails 5+)
end

# Many-to-many through a join table
class Issue < ApplicationRecord
  has_many :issue_labels, dependent: :destroy
  has_many :labels, through: :issue_labels
end

class Label < ApplicationRecord
  has_many :issue_labels, dependent: :destroy
  has_many :issues, through: :issue_labels
end

class IssueLabel < ApplicationRecord
  belongs_to :issue
  belongs_to :label
  # belongs_to validates presence automatically — no need to add it manually
end
```

### `dependent:` options

| Option | Behaviour | Use when |
|---|---|---|
| `:destroy` | Loads each child into Ruby, calls `.destroy` — **triggers callbacks** | Children have their own associations/callbacks |
| `:delete_all` | Single `DELETE` SQL — **skips callbacks** | Leaf nodes, performance-critical bulk deletes |
| `:nullify` | Sets FK to `NULL`, children survive | e.g. deleting a user shouldn't delete their issues |
| `:restrict_with_error` | Blocks deletion, adds error to model | Must explicitly remove children first |
| `:restrict_with_exception` | Blocks deletion, raises exception | Same but raises instead |

> **Critical gotcha**: If `Project` uses `:delete_all` on issues, but `Issue` has `dependent: :destroy` on `issue_labels`, the cascade **breaks** — `delete_all` skips Ruby entirely, so `IssueLabel` rows become orphaned.

### `has_many :through` vs direct association

`has_many :labels, through: :issue_labels` gives you:

```ruby
issue.labels          # => all Label records — ActiveRecord collection
issue.labels.pluck(:name)   # => ["backend", "bug"] — direct SQL, no Ruby objects
issue.labels << Label.find(1)  # adds to join table automatically
issue.labels.destroy(label)    # removes from join table, doesn't delete label
```

---

## 4. Validations

### Built-in validators

```ruby
validates :name,     presence: true
validates :title,    length: { maximum: 255 }
validates :title,    length: { in: 3..255 }
validates :email,    uniqueness: { case_sensitive: false }
validates :email,    uniqueness: { scope: :project_id }  # unique within project
validates :age,      numericality: { greater_than: 0, only_integer: true }
validates :status,   inclusion: { in: %w[open closed] }
validates :color,    format: { with: /\A#[0-9A-Fa-f]{6}\z/, message: "must be a valid hex color" }
validates :terms,    acceptance: true
validates :password, confirmation: true  # requires :password_confirmation field
```

### Conditional validations

```ruby
validates :due_date, presence: true, if: :in_progress?
validates :reason,   presence: true, unless: -> { status == "draft" }
```

### Custom validator methods

```ruby
validate :due_date_cannot_be_in_the_past

private

def due_date_cannot_be_in_the_past
  if due_date.present? && due_date < Date.today
    errors.add(:due_date, "can't be in the past")
  end
end
```

### Checking errors

```ruby
issue = Issue.new
issue.valid?                    # => false — triggers validations
issue.errors.full_messages      # => ["Title can't be blank"]
issue.errors[:title]            # => ["can't be blank"]
```

### Skipping validations — use with caution

```ruby
record.save(validate: false)      # skips validations, runs callbacks
record.update_column(:name, "x")  # skips validations AND callbacks — code smell
```

---

## 5. Enums

### Declaration

```ruby
class Issue < ApplicationRecord
  enum :status, { open: 0, in_progress: 1, closed: 2 }
end
```

Stores **integers** in the DB (fast, indexed) but exposes a **human-readable API**:

```ruby
issue.open?         # => true       — predicate methods
issue.in_progress!  # persists to DB — bang methods
issue.closed!

issue.status        # => "open"     — string key, not integer
issue.status = :closed              # accepts symbol or string

Issue.open          # => ActiveRecord scope — WHERE status = 0
Issue.in_progress
Issue.closed
```

### ⚠️ Always use the hash form

```ruby
# ✅ Safe — integers are explicit and stable
enum :status, { open: 0, in_progress: 1, closed: 2 }

# ❌ Dangerous — inserting a value shifts all integers
enum :status, [:open, :in_progress, :closed]
```

---

## 6. Creating & Updating Records

### Bang vs non-bang

| Method | On failure |
|---|---|
| `create` / `save` / `update` | Returns `false` or unsaved record with `errors` |
| `create!` / `save!` / `update!` | Raises `ActiveRecord::RecordInvalid` |

**Use bang (`!`) in**: seeds, tests, rake tasks, rails runner — fail loudly  
**Use non-bang in**: controllers — handle the failure case and re-render the form

### `find` vs `find_by`

```ruby
Project.find(99)        # raises ActiveRecord::RecordNotFound → Rails returns 404 automatically
Project.find_by(id: 99) # returns nil if missing
```

Prefer `find` in controllers — free 404 handling.

### All the ways to update

```ruby
# Runs validations + callbacks (standard)
project.update(name: "New")
project.update!(name: "New")

# Inspect before saving
project.assign_attributes(name: "New")
project.changed?    # => true
project.changes     # => {"name" => ["Old", "New"]}
project.save

# Bypass validations and callbacks — use sparingly
project.update_column(:name, nil)           # one column, skips everything
project.update_columns(name: nil, desc: "") # multiple columns, skips everything
Issue.where(status: :open).update_all(status: :closed)  # pure SQL, no instances loaded
```

### Dirty tracking

```ruby
issue.status = :closed
issue.changed?          # => true
issue.status_changed?   # => true
issue.status_was        # => "open"
issue.changes           # => {"status" => ["open", "closed"]}

# After save:
issue.saved_changes          # => {"status" => ["open", "closed"]}
issue.status_previously_was  # => "open"
```

Dirty tracking is powerful inside callbacks:

```ruby
after_update :notify_if_closed

def notify_if_closed
  send_notification if status_previously_changed? && closed?
end
```

---

## 7. Zeitwerk — The Rails Autoloader

Zeitwerk is Rails' autoloader (default since Rails 6). You **never write `require`** in Rails — files load automatically on demand.

### The convention

```
app/models/project.rb                    → Project
app/models/issue_label.rb               → IssueLabel
app/controllers/projects_controller.rb  → ProjectsController
app/services/billing/invoicer.rb        → Billing::Invoicer
```

**One file = one constant**, named exactly as the file implies. Breaking this crashes the app at boot in production.

### How loading works

```
1. App boots → Zeitwerk scans all app/** directories
2. Builds a map: constant name → file path
3. First time code references `Project` → Zeitwerk loads the file
4. Subsequent references → already in memory
```

### Development vs Production

| Environment | `eager_load` | Behaviour |
|---|---|---|
| Development | `false` | Lazy loads on demand, watches for file changes, reloads between requests |
| Production | `true` | Eager loads everything at boot — no file watching, faster requests |

### Validation

```bash
rails zeitwerk:check   # validates all files follow naming conventions
```

### Common gotchas

```ruby
# ❌ Wrong casing
class Issuelabel; end   # in issue_label.rb — Zeitwerk expects IssueLabel

# ❌ Two constants in one file
class Issue; end
class IssueLabel; end   # second one won't be autoloaded

# ❌ Acronyms — need configuration
# APIClient in api_client.rb fails without:
ActiveSupport::Inflector.inflections(:en) do |inflect|
  inflect.acronym "API"
end
```

---

## 8. Routing & Nested Resources

### Our routes

```ruby
Rails.application.routes.draw do
  resources :projects do
    resources :issues, shallow: true
  end
end
```

### What `shallow: true` generates

**Collection routes** (need project context — include `:project_id`):

```
GET  /projects/:project_id/issues      → issues#index
POST /projects/:project_id/issues      → issues#create
GET  /projects/:project_id/issues/new  → issues#new
```

**Member routes** (issue ID is enough — no `:project_id` needed):

```
GET    /issues/:id       → issues#show
GET    /issues/:id/edit  → issues#edit
PATCH  /issues/:id       → issues#update
DELETE /issues/:id       → issues#destroy
```

> Once you have `issue.id`, you can always get the project via `issue.project` — no need to carry `:project_id` in every URL.

### Route helpers generated

```ruby
projects_path              # => /projects
project_path(@project)     # => /projects/1
new_project_path           # => /projects/new
edit_project_path(@project)# => /projects/1/edit

project_issues_path(@project)      # => /projects/1/issues
new_project_issue_path(@project)   # => /projects/1/issues/new
issue_path(@issue)                 # => /issues/1
edit_issue_path(@issue)            # => /issues/1/edit
```

### Nesting depth best practice

> Never nest resources more than 1 level deep. `/projects/:project_id/issues/:issue_id/comments/:id` is hard to maintain and leaks implementation details into URLs. Use `shallow: true` or restructure.

---

## 9. Controllers

### `before_action` — DRY setup

```ruby
class ProjectsController < ApplicationController
  before_action :set_project, only: %i[show edit update destroy]

  private

  def set_project
    @project = Project.find(params[:id])  # raises 404 automatically if not found
  end
end
```

### Strong Parameters — security

```ruby
def project_params
  params.require(:project).permit(:name, :description)
end
```

- `require(:project)` — the params hash must have a `:project` key
- `permit(:name, :description)` — only these keys pass through; everything else is stripped
- Prevents **mass assignment attacks** — without this, a user could POST `admin: true`

### Standard CRUD pattern

```ruby
def create
  @project = Project.new(project_params)

  if @project.save
    redirect_to @project, notice: "Project created."
  else
    render :new, status: :unprocessable_entity  # 422, not 200
  end
end
```

> **Why 422?** Turbo (Hotwire) only replaces the form DOM on a 422 response. Returning 200 on a failed form submission breaks Turbo's form handling.

### Shallow nesting in controllers

With shallow routes, `IssuesController` handles two contexts:

```ruby
class IssuesController < ApplicationController
  # new/create need project context — params[:project_id]
  before_action :set_project, only: %i[new create]

  # show/edit/update/destroy only need the issue — params[:id]
  before_action :set_issue,   only: %i[show edit update destroy]

  private

  def set_project
    @project = Project.find(params[:project_id])
  end

  def set_issue
    @issue = Issue.find(params[:id])
  end
end
```

---

## 10. Views, Partials & Form Helpers

### The partial naming convention

Files prefixed with `_` are **partials** — reusable view fragments. They are never rendered directly; always rendered from another view via `render`.

```
app/views/issues/_form.html.erb   ← partial (note the underscore)
app/views/issues/new.html.erb     ← full view, renders the partial
app/views/issues/edit.html.erb    ← full view, renders the same partial
```

### Why one `_form` partial for both `new` and `edit`?

Both forms have identical fields — only the URL and HTTP method differ. Rails handles that automatically based on whether the model is persisted or not:

```erb
<%# new.html.erb %>
<%= render 'form', issue: @issue, project: @project %>

<%# edit.html.erb %>
<%= render 'form', issue: @issue, project: @issue.project %>
```

Variables passed to `render` become local variables inside the partial — `@issue` (instance variable) becomes `issue` (local variable). This makes partials reusable across different contexts.

### The shallow routing problem with `form_with`

With shallow nested routes, `form_with(model: issue)` alone cannot determine the correct URL for a **new** issue — it would try `POST /issues` which doesn't exist. The URL must be explicit:

```erb
<%= form_with(model: issue, url: issue.new_record? ? project_issues_path(project) : issue_path(issue)) do |form| %>
```

| Scenario | `new_record?` | URL used |
| --- | --- | --- |
| Creating a new issue | `true` | `POST /projects/:project_id/issues` |
| Editing an existing issue | `false` | `PATCH /issues/:id` |

### `new_record?` — how Rails knows the form action

```ruby
issue.new_record?   # => true  — not yet saved to DB (no id)
                    # => false — exists in DB (has id)

# Counterpart:
issue.persisted?    # => opposite of new_record?
```

### `local: true` is no longer needed

In **Rails 6.1+**, `form_with` submits via standard HTTP by default. `local: true` used to be required to opt out of Ajax submission — it's now the default. You only need `local: false` to explicitly enable Ajax.

### Building a `<select>` from an enum

```erb
<%= form.select :status, Issue.statuses.keys.map { |s| [s.humanize, s] }, { include_blank: false } %>
```

`form.select` expects `[label_to_display, value_to_submit]` pairs:

```ruby
Issue.statuses                               # => { "open" => 0, "in_progress" => 1, "closed" => 2 }
Issue.statuses.keys                          # => ["open", "in_progress", "closed"]
Issue.statuses.keys.map { |s| [s.humanize, s] }
# => [["Open", "open"], ["In progress", "in_progress"], ["Closed", "closed"]]
```

If you add a new status to the enum, the dropdown updates automatically — no hardcoded strings in the view.

### Navigating to the project from a shallow edit route

In the `edit` action, only `@issue` is loaded (no `@project`) because it's a shallow route. Navigate through the association:

```erb
<%# edit.html.erb — @project is not set, so use the association %>
<%= render 'form', issue: @issue, project: @issue.project %>
```

### Accessing `edit` via `@issue.project` triggers a DB query

```ruby
@issue.project   # SELECT * FROM projects WHERE id = ? — one extra query
```

This is fine for single records. For lists, use `includes` to avoid N+1 (covered in a future section).

---

## 11. String Helpers — humanize, pluralize & Inflector

### `humanize`

Transforms machine-readable strings into human-readable ones. From **ActiveSupport**.

```ruby
"in_progress".humanize                    # => "In progress"
"open".humanize                           # => "Open"
"employee_salary".humanize                # => "Employee salary"
"author_id".humanize                      # => "Author"        ← strips _id suffix
"_mystring".humanize                      # => "Mystring"      ← strips leading _
"employee_salary".humanize(capitalize: false)  # => "employee salary"
```

Rules applied in order:

1. Strip leading underscores
2. Remove `_id` suffix
3. Replace `_` with spaces
4. Capitalise the first word only

### `pluralize` — view helper

```ruby
pluralize(1, "error")   # => "1 error"
pluralize(2, "error")   # => "2 errors"
pluralize(0, "error")   # => "0 errors"

# Handles irregular words via the Inflector:
pluralize(2, "person")  # => "2 people"   ← not "persons"
pluralize(2, "mouse")   # => "2 mice"
pluralize(2, "sheep")   # => "2 sheep"    ← uncountable

# Override the plural:
pluralize(2, "error", plural: "mistakes")  # => "2 mistakes"
```

`pluralize` is a **view helper** from `ActionView::Helpers::TextHelper` — available in all views automatically. Outside views, use the underlying method:

```ruby
"error".pluralize      # => "errors"
"error".pluralize(1)   # => "error"
"error".pluralize(2)   # => "errors"
```

### Full Inflector reference

All from **ActiveSupport::Inflector**, available on any String in Rails:

```ruby
"in_progress".humanize    # => "In progress"     — readable label
"in_progress".titleize    # => "In Progress"      — every word capitalised
"in_progress".capitalize  # => "In_progress"      — only first char, keeps underscores!
"InProgress".underscore   # => "in_progress"      — CamelCase to snake_case
"in_progress".camelize    # => "InProgress"       — snake_case to CamelCase
"issue".pluralize         # => "issues"
"issues".singularize      # => "issue"
"IssueLabel".tableize     # => "issue_labels"     — used by ActiveRecord for table names
"issue_label".classify    # => "IssueLabel"       — used by ActiveRecord for class names
"Issue".foreign_key       # => "issue_id"         — used for FK column names
```

> **Interview insight**: The Inflector powers Rails' naming conventions end-to-end. `Issue` model → `issues` table (`tableize`), `project_id` FK (`foreign_key`), `IssueLabel` from `issue_label.rb` (`classify`). Zeitwerk uses the same engine. When Rails gets a word wrong (e.g. "octopi" vs "octopuses"), fix it in `config/initializers/inflections.rb`.

---

## 12. Initializers

### What are initializers?

Files in `config/initializers/` run **once at boot**, after the framework loads but before the app starts serving requests. Used for configuration that must happen early and only once.

> ⚠️ Always restart the server after modifying an initializer — unlike models/controllers, they are **not** reloaded between requests in development.

### Load order

Initializers run in **alphabetical order** by filename. If B depends on A, use numeric prefixes:

```
config/initializers/
  01_core_config.rb    ← runs first
  02_devise.rb         ← can safely depend on 01
  03_sidekiq.rb        ← can depend on 01 and 02
```

Rails' own internal initializers always run before yours.

### The four default initializers

#### `inflections.rb` — Teach Rails new words

```ruby
ActiveSupport::Inflector.inflections(:en) do |inflect|
  inflect.plural /^(ox)$/i, '\1en'        # regex rule: ox → oxen
  inflect.singular /^(ox)en/i, '\1'       # oxen → ox
  inflect.irregular "person", "people"    # one-off exception
  inflect.uncountable %w(fish sheep)      # same singular and plural

  inflect.acronym "API"      # api_controller.rb → APIController not ApiController
  inflect.acronym "OAuth"
  inflect.acronym "GraphQL"
end
```

#### `filter_parameter_logging.rb` — Protect sensitive data in logs

```ruby
Rails.application.config.filter_parameters += [
  :passw, :email, :secret, :token, :_key, :cvv
]
```

Without this, passwords appear in plain text in log files:

```
# Unfiltered — security incident:
Parameters: {"user"=>{"password"=>"mysecret123"}}

# Filtered — safe:
Parameters: {"user"=>{"password"=>"[FILTERED]"}}
```

> **Interview point**: At GitLab scale, logs are shipped to centralised systems (Elasticsearch, Splunk). An unfiltered password in a log is a serious security incident. Always extend this list when adding sensitive fields.

#### `content_security_policy.rb` — Browser security headers

```ruby
config.content_security_policy do |policy|
  policy.default_src :self, :https   # only load from own domain over HTTPS
  policy.script_src  :self, :https   # no inline scripts, no third-party JS
  policy.object_src  :none           # block Flash and plugins entirely
  policy.img_src     :self, :https, :data
  policy.report_uri  "/csp-violation-report-endpoint"
end
```

Sets the `Content-Security-Policy` HTTP header — tells browsers what resources they can load. Prevents XSS attacks even if an attacker manages to inject a `<script>` tag.

#### `assets.rb` — Asset pipeline config

```ruby
Rails.application.config.assets.version = "1.0"
# Bump this to bust the browser cache for ALL assets at once

Rails.application.config.assets.paths << Rails.root.join("vendor/assets")
# Add extra directories for the asset pipeline to search
```

### Common initializers you'll create yourself

```ruby
# config/initializers/sidekiq.rb
Sidekiq.configure_server do |config|
  config.redis = { url: ENV["REDIS_URL"] }
end

# config/initializers/cors.rb — for API apps
Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    origins "app.example.com"
    resource "/api/*", headers: :any, methods: [:get, :post]
  end
end

# config/initializers/constants.rb
SUPPORTED_LOCALES = %w[en fr de ja].freeze
MAX_UPLOAD_SIZE   = 10.megabytes
```

---

*Next up: Scopes, N+1 queries & eager loading*

---

## Quick Reference: Key Rails Commands

```bash
rails new app_name -d postgresql   # new app with postgres
rails generate model User name:string email:string
rails generate controller Projects index show new
rails generate migration AddColumnToTable column:type
rails db:create                    # create databases
rails db:migrate                   # run pending migrations
rails db:migrate:status            # check migration status
rails db:rollback                  # undo last migration
rails db:schema:load               # load schema.rb (faster than migrate on fresh DB)
rails routes                       # list all routes
rails zeitwerk:check               # validate autoloading conventions
rails runner "puts Project.count"  # run Ruby code in app context
rails console                      # interactive REPL with app loaded
```

---

## 13. Scopes

Scopes are named, reusable query fragments defined on the model. They return an `ActiveRecord::Relation` so they are **chainable**.

### Defining scopes

```ruby
class Issue < ApplicationRecord
  scope :recent,      -> { order(created_at: :desc) }
  scope :by_status,   ->(status) { where(status: status) }
  scope :with_labels, -> { includes(:labels) }
end
```

The `->` is a **lambda** — it ensures the scope is evaluated lazily at call time, not at class load time. This matters for time-based scopes:

```ruby
# ❌ Wrong — evaluated once at boot, date never changes
scope :recent, where("created_at > ?", 1.week.ago)

# ✅ Correct — lambda evaluated fresh on every call
scope :recent, -> { where("created_at > ?", 1.week.ago) }
```

### Chaining scopes

Because each scope returns a relation, you can chain them freely:

```ruby
Issue.recent.by_status(:open).with_labels
# => SELECT issues.* ... WHERE status = 0 ORDER BY created_at DESC
#    + separate query for labels via includes
```

### Scopes vs class methods

A scope is essentially syntactic sugar for a class method. These two are equivalent:

```ruby
# Scope
scope :open_issues, -> { where(status: :open) }

# Class method — identical behaviour
def self.open_issues
  where(status: :open)
end
```

Prefer scopes for simple queries (more expressive). Use class methods when you need conditionals or complex logic:

```ruby
def self.by_status(status)
  return all if status.blank?   # scopes can't easily do this — returns all records
  where(status: status)
end
```

> 💡 **Key insight**: A scope that returns `nil` breaks chaining — Rails replaces a `nil` return from a scope with `all` automatically. A class method that returns `nil` does **not** get this protection — it would raise a `NoMethodError` when chained. Another reason to use class methods with explicit `return all` guards.

### Enum scopes — free from the enum declaration

```ruby
enum :status, { open: 0, in_progress: 1, closed: 2 }
# Automatically creates:
Issue.open         # WHERE status = 0
Issue.in_progress  # WHERE status = 1
Issue.closed       # WHERE status = 2
```

These are just scopes generated for free — fully chainable with your own scopes:

```ruby
Issue.open.recent.with_labels
```

---

## 14. N+1 Queries & Eager Loading

### What is an N+1?

A loop that fires one query per iteration instead of loading everything upfront:

```ruby
# 1 query to load projects
projects = Project.all

projects.each do |project|
  project.issues.each do |issue|    # 1 query per project (N)
    issue.labels.map(&:name)        # 1 query per issue (N×M)
  end
end
# Total: 1 + N + (N×M) queries
# With 3 projects, 5 issues each: 1 + 3 + 15 = 19 queries
# With 100 projects, 50 issues each: 1 + 100 + 5000 = 5101 queries
```

The tell-tale sign in logs: **the same SQL repeated with only the `id` changing**.

### The fix — `includes`

```ruby
# Loads everything in 3 queries regardless of record count
Project.includes(issues: :labels)

# Query 1: SELECT projects.*
# Query 2: SELECT issues.* WHERE project_id IN (1, 2, 3)
# Query 3: SELECT labels.* WHERE id IN (1, 2, 3, ...)
# Rails stitches associations together in Ruby memory
```

### `includes` vs `preload` vs `eager_load`

| Method | SQL strategy | Use when |
| --- | --- | --- |
| `includes` | Auto-picks (see below) | Always — it chooses the best strategy |
| `preload` | Separate `IN` queries always | Force separate queries |
| `eager_load` | `LEFT OUTER JOIN` always | Force a JOIN |

**`includes` auto-switching behaviour:**

```ruby
# No where/order on association → uses separate IN queries (preload strategy)
Issue.includes(:labels)
# SELECT issues.* ...
# SELECT labels.* WHERE id IN (...)

# References associated table in where/order → switches to LEFT OUTER JOIN
Issue.includes(:labels).where(labels: { name: "backend" })
# SELECT issues.*, labels.* FROM issues
# LEFT OUTER JOIN issue_labels ON ...
# LEFT OUTER JOIN labels ON ...
# WHERE labels.name = 'backend'
```

### Applying the fix to the index page scenario

If you want to show labels on the projects index page, you must eager load the full chain:

```ruby
# Controller — index action
@projects = Project.includes(issues: :labels).order(created_at: :desc)
#                            ^^^^^^^^^^^^^^^ nested includes syntax
```

Without this, the view loop:

```erb
<% @projects.each do |project| %>
  <% project.issues.each do |issue| %>
    <% issue.labels.each do |label| %>   ← N×M extra queries
```

...fires a query for every single issue's labels.

### `joins` vs `includes` — a critical distinction

```ruby
Project.joins(:issues)
# INNER JOIN — filters to projects WITH issues
# Does NOT load issues into memory
# project.issues still fires a new query!

Project.includes(:issues)
# Loads issues into memory
# project.issues uses cached data — no extra query
```

Use `joins` for **filtering**. Use `includes` for **displaying data**.

```ruby
# Find projects that have open issues, and display those issues' labels
Project.joins(:issues)
       .where(issues: { status: :open })
       .includes(issues: :labels)
       .distinct
```

### Rails query cache

Within a single request, Rails caches identical SQL queries. If the same query fires twice, the second hit returns instantly from memory — you'll see `CACHE` in the logs:

```
Issue Load (2.1ms)  SELECT "issues".* WHERE project_id IN (1,2,3)
CACHE Issue Load (0.0ms)  SELECT "issues".* WHERE project_id IN (1,2,3)  ← free
```

### Detecting N+1s automatically — the `bullet` gem

Add to `Gemfile`:

```ruby
group :development do
  gem "bullet"
end
```

Configure in `config/environments/development.rb`:

```ruby
config.after_initialize do
  Bullet.enable       = true
  Bullet.alert        = true   # browser alert popup
  Bullet.rails_logger = true   # log to Rails logger
end
```

Bullet will automatically warn you whenever an N+1 is detected during development — you don't have to manually read logs.

---

## 15. SQL Joins

Using our data as an example:

```
projects              issues
--------              ------
1  Alpha              1  Fix bug      project_id: 1
2  Beta               2  Add feature  project_id: 1
3  Gamma              (no issues for Beta or Gamma)
```

### INNER JOIN

Returns rows where there is a match **in both tables**. Unmatched rows are dropped.

```sql
SELECT projects.name, issues.title
FROM projects INNER JOIN issues ON issues.project_id = projects.id
-- Result:
-- Alpha | Fix bug
-- Alpha | Add feature
-- Beta and Gamma disappear — they had no issues
```

**ActiveRecord**: `Project.joins(:issues)` — use for filtering to records that have associations.

### LEFT OUTER JOIN

Returns **all rows from the left table**. Unmatched right-side columns are `NULL`.

```sql
SELECT projects.name, issues.title
FROM projects LEFT OUTER JOIN issues ON issues.project_id = projects.id
-- Result:
-- Alpha | Fix bug
-- Alpha | Add feature
-- Beta  | NULL    ← kept even with no issues
-- Gamma | NULL    ← kept even with no issues
```

**ActiveRecord**: `Project.left_outer_joins(:issues)` or `Project.eager_load(:issues)`.
Use when you need **all records regardless of whether they have associations**.

### RIGHT OUTER JOIN

Opposite of LEFT — keeps all rows from the **right table**, `NULL` for unmatched left side. Rarely used in Rails (just flip table order and use LEFT JOIN instead).

### FULL OUTER JOIN

All rows from **both** tables. `NULL` fills in wherever there's no match on either side. Not available in ActiveRecord directly — requires `find_by_sql` with raw SQL.

### CROSS JOIN

Every row from the left combined with every row from the right (cartesian product). 3 projects × 3 issues = 9 rows. Rarely useful.

### Quick decision guide

```
Need all records even with no associations?  → LEFT OUTER JOIN
Only want records that have associations?    → INNER JOIN
Filtering/sorting by an associated column?   → INNER or LEFT OUTER JOIN
Just eager loading for display?              → let includes use separate IN queries
```

### Key Rails gotcha — `joins` does NOT load data

```ruby
project = Project.joins(:issues).first
project.issues   # ← fires ANOTHER query! joins only filtered, didn't load
```

vs

```ruby
project = Project.eager_load(:issues).first
project.issues   # ← no extra query — data already in memory
```

---

*Next up: Testing with RSpec / Minitest*
