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
16. [Zero-Downtime Migrations](#16-zero-downtime-migrations)
17. [DDL Transactions & Index Algorithms](#17-ddl-transactions--index-algorithms)
18. [PostgreSQL Deep Dive](#18-postgresql-deep-dive)
19. [Foreign Keys, Database Locks & Constraint Patterns](#19-foreign-keys-database-locks--constraint-patterns)
20. [Migration Methods — `change` vs `up`/`down`](#20-migration-methods--change-vs-updown)
21. [Testing with RSpec — The GitLab Way](#21-testing-with-rspec--the-gitlab-way)
22. [Ruby Particularities — Truthiness, Identity & Gotchas](#22-ruby-particularities--truthiness-identity--gotchas)
23. [Multi-Format Responses — `respond_to` and the JSON API Pattern](#23-multi-format-responses--respond_to-and-the-json-api-pattern)
24. [Jbuilder — JSON View Templates](#24-jbuilder--json-view-templates)
25. [Where Logic Lives — Model, Controller, Service Object & Beyond](#25-where-logic-lives--model-controller-service-object--beyond)

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

```text
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
| --- | --- | --- |
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
| --- | --- |
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

```text
app/models/project.rb                    → Project
app/models/issue_label.rb               → IssueLabel
app/controllers/projects_controller.rb  → ProjectsController
app/services/billing/invoicer.rb        → Billing::Invoicer
```

**One file = one constant**, named exactly as the file implies. Breaking this crashes the app at boot in production.

### How loading works

```text
1. App boots → Zeitwerk scans all app/** directories
2. Builds a map: constant name → file path
3. First time code references `Project` → Zeitwerk loads the file
4. Subsequent references → already in memory
```

### Development vs Production

| Environment | `eager_load` | Behaviour |
| --- | --- | --- |
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

```text
GET  /projects/:project_id/issues      → issues#index
POST /projects/:project_id/issues      → issues#create
GET  /projects/:project_id/issues/new  → issues#new
```

**Member routes** (issue ID is enough — no `:project_id` needed):

```text
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

```text
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

```text
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

```text
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

```text
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

```text
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

```text
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

## 16. Zero-Downtime Migrations

When you have millions of rows and live traffic, a naive migration can lock a table for minutes, causing 503 errors. The app must keep working with **both the old and new schema simultaneously** during a deploy.

> GitLab enforces zero-downtime migration patterns through a custom CI linter — any migration that could cause a lock on a large table fails the pipeline automatically.

### The naive (dangerous) approach

```ruby
# ❌ On PostgreSQL < 11, this rewrites the entire table — minutes of lock
add_column :issues, :author_name, :string, null: false, default: "unknown"
```

### The safe 3-step pattern

Split what would be one migration into three, deployed separately:

#### Step 1 — Add the column nullable, no default (instant, no lock)

```ruby
class AddAuthorNameToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :author_name, :string
    # Nullable by design — old code ignores it, new code can write to it
    # No table rewrite, no lock, completes in milliseconds
  end
end
```

**During this deploy**: old code ignores the new column ✅, new code reads/writes it ✅.

#### Step 2 — Backfill existing NULL rows in batches

Never backfill inside a migration that holds a lock. Use `in_batches` with `disable_ddl_transaction!`:

```ruby
class BackfillAuthorNameOnIssues < ActiveRecord::Migration[8.1]
  disable_ddl_transaction! # each batch commits independently

  def up
    # Use a local anonymous model — immune to future app model changes
    klass = Class.new(ActiveRecord::Base) { self.table_name = "issues" }

    klass.where(author_name: nil).in_batches(of: 1000) do |batch|
      batch.update_all(author_name: "unknown")
      sleep(0.01) # brief pause — avoids overwhelming DB on huge tables
    end
  end

  def down; end
end
```

**Why an anonymous model?** If you use `Issue.where(...)` and later rename or remove the `Issue` class, this migration breaks when someone runs it on a fresh database. The anonymous model is self-contained.

#### Step 3 — Add NOT NULL constraint (after backfill confirmed complete)

```ruby
class AddNotNullToIssuesAuthorName < ActiveRecord::Migration[8.1]
  def up
    # Safe because zero NULLs remain in the table
    change_column_null :issues, :author_name, false

    # For very large tables, use PostgreSQL's non-blocking approach instead:
    # execute "ALTER TABLE issues ADD CONSTRAINT issues_author_name_not_null
    #          CHECK (author_name IS NOT NULL) NOT VALID;"
    # execute "ALTER TABLE issues VALIDATE CONSTRAINT issues_author_name_not_null;"
    # NOT VALID = instant (skips existing rows)
    # VALIDATE  = scans rows but only takes a SHARE lock (reads still work)
  end

  def down
    change_column_null :issues, :author_name, true
  end
end
```

### The 3-deploy timeline

```text
Deploy 1 → Step 1: add nullable column
           Old code: ignores column ✅  New code: writes to it ✅

Deploy 2 → Step 2: backfill NULLs in batches (zero lock)
           Confirm: zero NULL rows remain

Deploy 3 → Step 3: add NOT NULL constraint
           Safe because no NULLs exist ✅
```

### `in_batches` vs `find_each` vs `update_all`

```ruby
# update_all — one giant SQL, no Ruby objects, fastest — but locks whole table
Issue.update_all(author_name: "unknown")
# UPDATE issues SET author_name = 'unknown'  ← one huge lock

# find_each — loads rows into Ruby, triggers callbacks, fires N UPDATEs — very slow
Issue.find_each(batch_size: 1000) { |i| i.update!(author_name: "unknown") }

# in_batches + update_all — best of both worlds ✅
Issue.in_batches(of: 1000) { |batch| batch.update_all(author_name: "unknown") }
# UPDATE ... WHERE id IN (1..1000)   → COMMIT  (lock released)
# UPDATE ... WHERE id IN (1001..2000) → COMMIT  (lock released)
```

### Renaming a column — never rename directly

```ruby
# ❌ Breaks running app immediately — old code references old column name
rename_column :issues, :title, :subject

# ✅ Safe multi-step approach:
# 1. add_column :issues, :subject, :string
# 2. Write to BOTH columns in app code (transition period)
# 3. Backfill: Issue.in_batches { |b| b.update_all("subject = title") }
# 4. Switch reads to new column, deploy
# 5. Remove old column in a later deploy
```

### Removing a column — ignore it first

```ruby
# ❌ Remove column while app still references it → NoMethodError crash
remove_column :issues, :old_field

# ✅ Safe approach:
# Step 1 — Tell ActiveRecord to ignore the column BEFORE the migration
class Issue < ApplicationRecord
  self.ignored_columns += [:old_field]  # app stops reading/writing it
end
# Deploy this code first

# Step 2 — Now safely remove the column in a migration
remove_column :issues, :old_field
```

---

## 17. DDL Transactions & Index Algorithms

### What is DDL?

**DDL** (Data Definition Language) = SQL that changes database **structure**:

```sql
-- DDL — structure changes
ALTER TABLE issues ADD COLUMN author_name VARCHAR
CREATE INDEX index_issues_on_status ON issues (status)
DROP TABLE labels

-- DML — data changes (not DDL)
INSERT INTO issues ...
UPDATE issues SET author_name = 'x'
SELECT * FROM issues
```

### Why Rails wraps migrations in transactions

By default every migration runs inside a transaction:

```sql
BEGIN
  ALTER TABLE issues ADD COLUMN ...  -- acquires exclusive lock
  UPDATE issues SET ...
COMMIT  -- lock released only here
```

If anything fails, the `ROLLBACK` undoes the entire migration — your schema is never left half-applied. This is only possible because **PostgreSQL supports transactional DDL** (unlike MySQL/MariaDB, where `ALTER TABLE` auto-commits and cannot be rolled back).

### The lock problem

An exclusive lock from `ALTER TABLE` blocks ALL other queries against that table for the transaction's duration:

```text
ALTER TABLE issues ADD COLUMN ...  ← exclusive lock acquired
  ← SELECT * FROM issues           → BLOCKED (user gets spinner)
  ← INSERT INTO issues ...         → BLOCKED
COMMIT                             ← lock released, blocked queries run
```

On a table with 50 million rows, a migration that rewrites rows can hold this lock for **minutes**.

### `disable_ddl_transaction!`

Opts out of the wrapping transaction — each statement commits immediately:

```ruby
class MyMigration < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    # Each statement commits on its own
    # DB can serve other queries between statements
    # Tradeoff: no automatic rollback if migration fails halfway
  end
end
```

Required for:

- `algorithm: :concurrently` index builds
- Large batched backfills

### `add_index` algorithms

#### `algorithm: :default` (implicit default)

```ruby
add_index :issues, :status
```

```sql
CREATE INDEX index_issues_on_status ON issues (status)
```

- Acquires **exclusive lock** — blocks all reads and writes during build
- Single pass — faster to complete
- Safe inside a transaction
- Use for: new tables, small tables, initial setup

#### `algorithm: :concurrently`

```ruby
class AddIndexToIssuesStatus < ActiveRecord::Migration[8.1]
  disable_ddl_transaction! # required — concurrent index can't run in a transaction

  def change
    add_index :issues, :status, algorithm: :concurrently
  end
end
```

```sql
CREATE INDEX CONCURRENTLY index_issues_on_status ON issues (status)
```

- Takes a **weaker lock** — reads and writes continue normally
- Multiple passes over the table — ~2-3x slower but non-blocking
- **Cannot run inside a transaction** — requires `disable_ddl_transaction!`
- Use for: **any table with live traffic**

How PostgreSQL builds it in 3 passes:

```text
Pass 1: Scan table, build initial index — normal writes still happen
Pass 2: Catch up on changes made during pass 1
Pass 3: Mark index as valid and ready to use
```

`remove_index` also supports concurrent:

```ruby
remove_index :issues, :status, algorithm: :concurrently
```

### Other index options

```ruby
# Unique index
add_index :issues, :title, unique: true

# Composite index — column order matters for query planning
add_index :issues, [:project_id, :status]
# Useful for: WHERE project_id = ? AND status = ?
# Also covers: WHERE project_id = ?  (leftmost prefix)
# NOT useful for: WHERE status = ?   (rightmost only)

# Partial index — only indexes rows matching a condition
# Much smaller and faster than a full index
add_index :issues, :project_id, where: "status = 0"
# Only indexes open issues — if 90% of queries filter by open,
# this index is 90% smaller and fits in memory

# Expression index (PostgreSQL specific)
add_index :issues, "lower(author_name)"
# Enables fast case-insensitive lookups:
# WHERE lower(author_name) = lower('Alice')

# Custom name (useful when auto-generated name exceeds 63 char limit)
add_index :issues, [:project_id, :status], name: "idx_issues_active_by_project"

# Combining concurrent + partial
add_index :issues, :project_id,
          where: "status != 2",
          algorithm: :concurrently,
          name: "idx_issues_active_project"
```

> **Interview insight — Partial indexes**: GitLab uses partial indexes extensively. If you have an `issues` table with 100M rows but 95% are `closed`, an index on `project_id WHERE status != 2` covers only the 5M active rows — fits in memory, blazing fast. Always ask "what percentage of rows does this index actually need to cover?"

---

## 18. PostgreSQL Deep Dive

### 18.1 Partial Indexes

A regular index covers **every row**. A partial index covers only rows **matching a WHERE condition** — smaller, faster, fits in RAM more easily.

```sql
-- Regular index — covers ALL 10M issues (~500MB)
CREATE INDEX idx_issues_project ON issues (project_id);

-- Partial index — covers only OPEN issues (5% of total, ~25MB)
CREATE INDEX idx_issues_active_project ON issues (project_id)
WHERE status = 0;
```

```ruby
# Rails:
add_index :issues, :project_id,
          where: "status = 0",
          algorithm: :concurrently,
          name: "idx_issues_active_project"
```

The query **must match the condition** to use the index:

```sql
-- Uses the partial index ✅
SELECT * FROM issues WHERE project_id = 5 AND status = 0;

-- Cannot use it ❌
SELECT * FROM issues WHERE project_id = 5;
```

Common real-world uses:

- `WHERE deleted_at IS NULL` — only index non-deleted records (soft deletes)
- `WHERE status != 'closed'` — only active work items
- `WHERE locked = false` — only available resources

### 18.2 Index Types

The default index type is **B-Tree** (Balanced Tree) — `O(log n)` lookups, supports `=`, `<`, `>`, `BETWEEN`, `LIKE 'abc%'` (prefix only). Does NOT help with `LIKE '%abc'` (suffix).

Other PostgreSQL index types:

```ruby
# GIN — Generalized Inverted Index
# Best for: arrays, JSONB, full-text search
add_index :issues, :tags, using: :gin
# Enables: WHERE tags @> '{backend}'

add_index :issues, "to_tsvector('english', description)", using: :gin
# Enables: full-text search

# GiST — Generalized Search Tree
# Best for: geometric data, ranges, fuzzy string matching
add_index :events, "tsrange(starts_at, ends_at)", using: :gist

# BRIN — Block Range Index
# Best for: naturally ordered huge tables (time-series, append-only logs)
# Tiny size — stores only min/max per block of pages
add_index :events, :created_at, using: :brin
# 10M rows → ~100KB vs ~500MB B-Tree

# Hash — equality only (=), slightly faster than B-Tree for pure equality
add_index :issues, :status, using: :hash
```

### 18.3 JSONB — PostgreSQL's Superpower

Native binary JSON — queryable and indexable:

```ruby
# Migration
add_column :issues, :metadata, :jsonb, default: {}
add_index :issues, :metadata, using: :gin  # indexes entire JSONB column
```

```ruby
# ActiveRecord querying
Issue.where("metadata->>'priority' = ?", "high")
Issue.where("metadata @> ?", { labels: ["bug"] }.to_json)  # contains
Issue.where("(metadata->>'score')::int > 5")
```

```sql
-- JSONB operators
metadata->>'key'             -- extract value as text
metadata->'key'              -- extract as JSONB (preserves type)
metadata @> '{"key":"val"}'  -- contains (uses GIN index) ✅ fast
metadata ? 'key'             -- key exists
metadata #>> '{a,b,c}'       -- nested path extraction
```

Always use `jsonb` over `json` — `json` stores raw text and re-parses on every access; `jsonb` stores binary format and supports indexing.

### 18.4 `EXPLAIN ANALYZE` — Reading Query Plans

Always check the query plan before adding an index — and after, to confirm it's being used:

```sql
EXPLAIN ANALYZE
SELECT * FROM issues WHERE project_id = 5 AND status = 0;
```

```text
Bitmap Heap Scan on issues  (cost=4.50..28.62 rows=12 width=150)
                             (actual time=0.082..0.091 rows=5 loops=1)
  ->  Bitmap Index Scan on idx_issues_active_project
        (actual time=0.071..0.071 rows=5 loops=1)
Planning Time: 0.3 ms
Execution Time: 0.4 ms
```

Key terms to know:

| Term | Meaning |
| --- | --- |
| `Seq Scan` | Full table scan — no index used, reads every row |
| `Index Scan` | Used an index, random heap access |
| `Bitmap Index Scan` | Used an index, batches heap accesses — efficient for multiple rows |
| `cost=X..Y` | Estimated cost (X=startup, Y=total) — relative units, not ms |
| `rows=N` | Estimated rows — if far off from actual, run `ANALYZE` to refresh stats |
| `actual time` | Real milliseconds — compare against estimated |

In Rails (safe to run in production — no ANALYZE):

```ruby
puts Issue.where(project_id: 5, status: :open).explain
```

### 18.5 Transactions & Isolation Levels

```ruby
# Wraps everything in BEGIN/COMMIT — if anything raises, full ROLLBACK
ActiveRecord::Base.transaction do
  project.update!(status: :archived)
  project.issues.update_all(status: :closed)
end
```

The 4 isolation levels and what they prevent:

| Level | Dirty Read | Non-repeatable Read | Phantom Read |
| --- | --- | --- | --- |
| `READ UNCOMMITTED` | possible | possible | possible |
| `READ COMMITTED` ← PG default | prevented | possible | possible |
| `REPEATABLE READ` | prevented | prevented | possible |
| `SERIALIZABLE` | prevented | prevented | prevented |

- **Dirty read**: reading uncommitted data from another transaction
- **Non-repeatable read**: same row read twice returns different values
- **Phantom read**: same query run twice returns different rows (insert/delete happened)

```ruby
# Use SERIALIZABLE for financial transactions
ActiveRecord::Base.transaction(isolation: :serializable) do
  account = Account.lock.find(id)  # SELECT FOR UPDATE — pessimistic lock
  account.update!(balance: account.balance - 100)
end
```

### 18.6 Pessimistic vs Optimistic Locking

**Pessimistic locking** — lock the row in the DB, others wait:

```ruby
# SELECT ... FOR UPDATE — blocks other transactions from updating this row
account = Account.lock.find(id)
account.update!(balance: account.balance - 100)
```

**Optimistic locking** — no DB lock, detect conflicts in Ruby:

```ruby
# Add lock_version column
add_column :issues, :lock_version, :integer, default: 0

# Rails increments lock_version on each update automatically
issue_a = Issue.find(1)  # lock_version: 5
issue_b = Issue.find(1)  # lock_version: 5

issue_a.update!(title: "First save")   # lock_version → 6 ✅
issue_b.update!(title: "Second save")  # raises ActiveRecord::StaleObjectError ❌
# The WHERE lock_version = 5 condition no longer matches
```

Use **pessimistic** for: financial operations, inventory — where conflicts are frequent and costly.
Use **optimistic** for: user-facing forms, low-contention updates — avoids DB-level locks at the cost of retry logic.

### 18.7 MVCC & VACUUM — Table Bloat

PostgreSQL uses **MVCC** (Multi-Version Concurrency Control) — it never overwrites rows, it writes new versions and marks old ones as dead:

```sql
UPDATE issues SET status = 1 WHERE id = 5;
-- Old row: (id:5, status:0) → marked DEAD, still on disk
-- New row: (id:5, status:1) → written to new page
```

Dead rows accumulate → **table bloat** → slower queries, wasted disk.

`VACUUM` cleans them up:

```sql
VACUUM issues;          -- removes dead rows, no table lock
VACUUM ANALYZE issues;  -- removes dead rows + refreshes query planner stats
VACUUM FULL issues;     -- reclaims disk, rewrites table — LOCKS the table
```

PostgreSQL runs **autovacuum** automatically, but on high-write tables it can fall behind. Check for bloat:

```ruby
ActiveRecord::Base.connection.execute(<<~SQL)
  SELECT relname,
         n_dead_tup,
         n_live_tup,
         round(n_dead_tup::numeric / nullif(n_live_tup, 0) * 100, 2) AS dead_pct
  FROM pg_stat_user_tables
  ORDER BY n_dead_tup DESC;
SQL
```

### 18.8 Connection Pooling

Every Rails request needs a DB connection. PostgreSQL has a hard connection limit (typically 100–500). At scale you need a **connection pooler**:

```text
Rails (Puma: 10 threads × 20 workers = 200 connections needed)
      ↓
  PgBouncer (connection pooler)
      ↓
PostgreSQL (max_connections = 100)
```

PgBouncer modes:

| Mode | Behaviour | Compatibility |
| --- | --- | --- |
| Session | One DB connection per client session | Full Rails compatibility |
| Transaction | Connection returned to pool after each transaction | GitLab uses this — most efficient |
| Statement | Connection returned after each statement | Incompatible with many Rails features |

Rails pool config in `database.yml`:

```yaml
pool: <%= ENV.fetch("RAILS_MAX_THREADS") { 5 } %>
```

> **Interview answer to "how does GitLab handle database scaling?"**: Horizontal read replicas for read traffic + PgBouncer in transaction mode for connection pooling + vertical scaling for the write primary + aggressive partial indexes and query optimization.

### 18.9 UPSERT — Insert or Update Atomically

```ruby
# Bulk upsert — Rails 6+
Issue.upsert_all(
  [
    { title: "Bug fix", status: 0, project_id: 1 },
    { title: "Feature", status: 0, project_id: 1 }
  ],
  unique_by: :title
)

# find_or_create_by — has a race condition in concurrent environments!
# Two processes both check "exists?" → both get "no" → both INSERT → conflict
Issue.find_or_create_by(title: "Bug fix")

# create_or_find_by — race-condition-safe ✅
# Attempts INSERT first, handles unique constraint conflict at DB level
Issue.create_or_find_by(title: "Bug fix") do |issue|
  issue.status = :open
  issue.project_id = 1
end
```

> `find_or_create_by` is a classic **TOCTOU** (Time-of-Check-Time-of-Use) race condition — always prefer `create_or_find_by` in concurrent contexts.

---

## 19. Foreign Keys, Database Locks & Constraint Patterns

### 19.1 What `t.references` actually generates

```ruby
t.references :issue, null: false, foreign_key: true
```

This one line expands into **three separate database operations**:

```sql
-- 1. The column itself
ALTER TABLE issue_labels ADD COLUMN issue_id bigint NOT NULL;

-- 2. An index (automatic with t.references)
CREATE INDEX index_issue_labels_on_issue_id ON issue_labels (issue_id);

-- 3. The foreign key constraint (only with foreign_key: true)
ALTER TABLE issue_labels
  ADD CONSTRAINT fk_issue_labels_issue_id
  FOREIGN KEY (issue_id) REFERENCES issues(id);
```

The longhand equivalent in a migration:

```ruby
t.bigint :issue_id, null: false
add_index :issue_labels, :issue_id
add_foreign_key :issue_labels, :issues
```

`null: false` and `foreign_key: true` are **completely independent**:

- `null: false` → NOT NULL column constraint. Prevents `NULL` in the column. Always cheap at table creation time.
- `foreign_key: true` → Referential integrity constraint. Prevents pointing to a non-existent row. This is the expensive, controversial one.

---

### 19.2 What a foreign key constraint enforces

PostgreSQL enforces referential integrity at the database level — **even if you bypass Rails entirely** (raw psql, scripts, direct DB connections):

```sql
-- Will FAIL if issue_id 9999 does not exist in issues table
INSERT INTO issue_labels (issue_id, label_id) VALUES (9999, 1);
-- ERROR: insert or update on table "issue_labels" violates foreign key constraint

-- Will FAIL if an issue_label still references this issue
DELETE FROM issues WHERE id = 1;
-- ERROR: update or delete on table "issues" violates foreign key constraint
```

In Rails, `belongs_to` presence validation catches the first case at the app layer, but DB constraints catch it everywhere else — including migrations, seeds, and scripts.

---

### 19.3 Foreign key tradeoffs — why GitLab omits them

| | DB Foreign Key (`foreign_key: true`) | No FK (application-level only) |
| --- | --- | --- |
| **Referential integrity** | Guaranteed at DB level | Only if all writes go through Rails |
| **Protection from raw SQL** | ✅ Yes | ❌ No |
| **Write throughput overhead** | Slight — each write checks parent table | None |
| **Migration safety on large tables** | Risky — takes locks during validation | No issue |
| **Cross-database (decomposition)** | ❌ Impossible | ✅ Works |
| **Orphaned records possible** | No | Yes, if app has bugs |
| **`rails db:schema:load`** | FK constraints included | No FK constraints |

GitLab's specific reasons:

1. **Scale** — billions of rows; any full-table scan for constraint validation causes downtime
2. **Cross-database decomposition** — CI tables live on a separate DB; FK constraints cannot span database boundaries
3. **Write throughput** — on extremely write-heavy tables (CI pipelines, audit logs), the per-write parent check is measurable
4. **Controlled access** — all DB writes go through the Rails app under strict review; raw DB writes are prohibited

**For your app**: `foreign_key: true` is the right call. The protections outweigh the overhead at any sane scale.

---

### 19.4 PostgreSQL Lock Types

PostgreSQL has **8 lock modes**, forming a conflict matrix. Every DDL and DML operation acquires one or more of these table-level locks:

| Lock Mode | Acquired by | Conflicts with |
| --- | --- | --- |
| `ACCESS SHARE` | `SELECT` | `ACCESS EXCLUSIVE` only |
| `ROW SHARE` | `SELECT FOR UPDATE/SHARE` | `EXCLUSIVE`, `ACCESS EXCLUSIVE` |
| `ROW EXCLUSIVE` | `INSERT`, `UPDATE`, `DELETE` | `SHARE`, `SHARE ROW EXCLUSIVE`, `EXCLUSIVE`, `ACCESS EXCLUSIVE` |
| `SHARE UPDATE EXCLUSIVE` | `VACUUM`, `ANALYZE`, `CREATE INDEX CONCURRENTLY` | `SHARE UPDATE EXCLUSIVE` and above |
| `SHARE` | `CREATE INDEX` (non-concurrent) | `ROW EXCLUSIVE` and above |
| `SHARE ROW EXCLUSIVE` | Constraint operations, `CREATE TRIGGER` | `ROW SHARE` and above |
| `EXCLUSIVE` | Rare, explicit `LOCK TABLE ... EXCLUSIVE` | `ROW SHARE` and above |
| `ACCESS EXCLUSIVE` | `ALTER TABLE`, `DROP TABLE`, `TRUNCATE`, `VACUUM FULL` | **Everything** — blocks all reads and writes |

The three that matter most in production:

**`ACCESS EXCLUSIVE`** — the most dangerous:

```sql
-- ALL of these take ACCESS EXCLUSIVE — they block every SELECT, INSERT, UPDATE, DELETE:
ALTER TABLE issues ADD COLUMN author_name text;
ALTER TABLE issue_labels ADD CONSTRAINT fk_... FOREIGN KEY (...) REFERENCES ...;
DROP TABLE issues;
TRUNCATE issues;
VACUUM FULL issues;
```

**`SHARE`** — blocks writes but not reads:

```sql
-- Non-concurrent index creation: reads still work, writes are blocked
CREATE INDEX index_issues_on_status ON issues (status);
```

**`SHARE UPDATE EXCLUSIVE`** — the "safe" lock for long-running operations:

```sql
-- Concurrent index creation: both reads AND writes continue normally
CREATE INDEX CONCURRENTLY index_issues_on_status ON issues (status);
```

Row-level locks are separate and only affect individual rows, not the whole table:

```sql
SELECT * FROM issues WHERE id = 1 FOR UPDATE;  -- only locks that one row
```

---

### 19.5 The lock queue problem

Locks don't just block — they **queue**. This is the silent killer on busy tables:

```text
Time 0ms:   Long-running SELECT starts        → holds ACCESS SHARE
Time 100ms: Your ALTER TABLE runs             → waits for ACCESS SHARE to finish
Time 101ms: New SELECT comes in               → waits behind ALTER TABLE (!)
Time 102ms: New INSERT comes in               → waits behind ALTER TABLE (!)
...
Time 30s:   ALTER TABLE times out             → lock_timeout exceeded
            All queued queries also fail or time out
```

A single DDL statement waiting in the queue blocks **all subsequent queries** on that table, even lightweight SELECTs. This is why `lock_timeout` is critical:

```ruby
# GitLab always sets this before risky migrations
execute "SET lock_timeout TO '5s'"
execute "SET statement_timeout TO '70s'"
add_index :issues, :status  # will FAIL FAST rather than queue up and cause cascade
```

---

### 19.6 Lock contention from foreign key validation

When you run `add_foreign_key` on a table with existing data:

```ruby
add_foreign_key :issue_labels, :issues
```

PostgreSQL must:

1. Take `SHARE ROW EXCLUSIVE` on `issue_labels` — blocks all writes
2. Take `SHARE ROW EXCLUSIVE` on `issues` — blocks all writes
3. **Scan the entire `issue_labels` table** to verify every `issue_id` exists in `issues`
4. Only then release both locks

On a table with 500M rows, step 3 takes minutes. During those minutes, **nothing can write to either table**.

---

### 19.7 The `NOT VALID` + `VALIDATE CONSTRAINT` pattern

PostgreSQL's solution: **split constraint creation into two steps** with completely different locking behaviors.

**Step 1** — Add the constraint but skip the historical data scan:

```ruby
# Migration 1
def change
  add_foreign_key :issue_labels, :issues, validate: false
  # Runs: ADD CONSTRAINT ... FOREIGN KEY ... NOT VALID
end
```

`NOT VALID` means:

- Constraint is created immediately (brief lock, no table scan)
- **New inserts/updates are validated from this point forward** ✅
- Existing rows are **not validated** — assumed to be clean from prior app-level checks

Lock: `SHARE ROW EXCLUSIVE` held briefly (no scan = milliseconds, not minutes).

**Step 2** — Validate the historical data separately (different deploy):

```ruby
# Migration 2
def change
  validate_foreign_key :issue_labels, :issues
  # Runs: ALTER TABLE issue_labels VALIDATE CONSTRAINT fk_...
end
```

`VALIDATE CONSTRAINT` does the full table scan but only acquires `SHARE UPDATE EXCLUSIVE` — which **does not block reads or writes**. Traffic continues normally during the scan.

Full safe pattern in Rails:

```ruby
# Step 1: Add constraint as NOT VALID — brief lock, deploy 1
class AddFkIssueLabelsToIssues < ActiveRecord::Migration[8.1]
  def change
    add_foreign_key :issue_labels, :issues, validate: false
  end
end

# Step 2: Validate — long scan, but zero-impact, deploy 2
class ValidateFkIssueLabelsToIssues < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!  # VALIDATE CONSTRAINT cannot run inside a transaction

  def change
    validate_foreign_key :issue_labels, :issues
  end
end
```

Why `disable_ddl_transaction!` on step 2? PostgreSQL cannot hold `SHARE UPDATE EXCLUSIVE` across a transaction boundary — the lock would be released on commit before the scan finished. The migration must run outside a transaction to keep the lock for the full duration.

---

### 19.8 Lock comparison — naive vs NOT VALID

| Approach | Lock held during scan | Blocks reads? | Blocks writes? | Downtime risk |
| --- | --- | --- | --- | --- |
| `add_foreign_key` (naive) | `SHARE ROW EXCLUSIVE` for full scan duration | ❌ No | ✅ Yes (minutes) | HIGH |
| `NOT VALID` step 1 | `SHARE ROW EXCLUSIVE` (milliseconds, no scan) | ❌ No | Briefly | LOW |
| `VALIDATE CONSTRAINT` step 2 | `SHARE UPDATE EXCLUSIVE` (full scan duration) | ❌ No | ❌ No | NONE |
| No FK at all | N/A | N/A | N/A | None |

---

### 19.9 The `NOT NULL` via check constraint trick

Adding `NOT NULL` to an existing column with data has the same problem — PostgreSQL needs `ACCESS EXCLUSIVE` and a full scan:

```ruby
# DANGEROUS on large tables:
change_column_null :issues, :author_name, false
# Runs: ALTER TABLE issues ALTER COLUMN author_name SET NOT NULL
# Takes ACCESS EXCLUSIVE + full scan — blocks everything
```

The safe alternative uses a check constraint with the same `NOT VALID` pattern:

```ruby
# Step 1: Add check constraint as NOT VALID (brief lock)
add_check_constraint :issues,
  "author_name IS NOT NULL",
  name: "check_issues_author_name_not_null",
  validate: false

# Step 2: Validate (zero-impact full scan)
class ValidateAuthorNameNotNull < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!
  def change
    validate_check_constraint :issues, name: "check_issues_author_name_not_null"
  end
end

# Step 3: Now safe to set NOT NULL — PostgreSQL sees the validated check constraint
# and skips the scan (it already knows all rows comply)
change_column_null :issues, :author_name, false
remove_check_constraint :issues, name: "check_issues_author_name_not_null"
```

PostgreSQL 12+ is smart enough to recognize that a validated check constraint proves NOT NULL safety, so the final `SET NOT NULL` is near-instant.

---

### 19.10 Common constraint types and their lock behavior

| Constraint | How to add safely | Lock type | Blocks writes? |
| --- | --- | --- | --- |
| `NOT NULL` | Check constraint + `NOT VALID` + `VALIDATE` | `SHARE UPDATE EXCLUSIVE` during validate | ❌ No |
| `FOREIGN KEY` | `NOT VALID` + `VALIDATE CONSTRAINT` | `SHARE UPDATE EXCLUSIVE` during validate | ❌ No |
| `CHECK` | `NOT VALID` + `VALIDATE CONSTRAINT` | `SHARE UPDATE EXCLUSIVE` during validate | ❌ No |
| `UNIQUE` | `CREATE UNIQUE INDEX CONCURRENTLY` + `ADD CONSTRAINT USING INDEX` | `SHARE UPDATE EXCLUSIVE` | ❌ No |
| `DEFAULT` (PG 11+) | `ALTER COLUMN SET DEFAULT` | `ACCESS EXCLUSIVE` (brief, no rewrite) | Briefly |
| `DEFAULT` (stored/computed) | Requires table rewrite | `ACCESS EXCLUSIVE` + rewrite | ✅ Yes (long) |

---

#### Next up: Testing with RSpec / Minitest

---

## 20. Migration Methods — `change` vs `up`/`down`

### The core difference

Every migration has one job: transform the schema. Rails gives you two ways to define that job:

- **`change`** — you describe the transformation once; Rails figures out how to reverse it automatically
- **`up` / `down`** — you describe both directions explicitly; Rails runs `up` on `db:migrate` and `down` on `db:rollback`

```ruby
# change — Rails infers the reverse
def change
  add_column :issues, :author_name, :string
  # Rails knows the reverse is: remove_column :issues, :author_name
end

# up/down — you define both directions yourself
def up
  add_column :issues, :author_name, :string
end

def down
  remove_column :issues, :author_name
end
```

For simple structural changes they are equivalent. The difference only matters when **Rails can't automatically infer the reverse**.

---

### How `change` works internally — reversible commands

Rails maintains an internal list of "reversible" migration commands. When you run `db:rollback`, it walks your `change` method **in reverse order** and calls the inverse of each command:

| Forward command | Auto-inferred reverse |
| --- | --- |
| `create_table` | `drop_table` |
| `drop_table` | ❌ Cannot infer (needs original column definitions) |
| `add_column` | `remove_column` |
| `remove_column` | ❌ Cannot infer (needs original type) |
| `rename_column` | `rename_column` (swaps names) |
| `rename_table` | `rename_table` (swaps names) |
| `add_index` | `remove_index` |
| `remove_index` | ❌ Cannot infer (needs original definition) |
| `add_reference` | `remove_reference` |
| `add_foreign_key` | `remove_foreign_key` |
| `change_column_null` | `change_column_null` (with opposite boolean) |
| `change_column_default` | ❌ Cannot infer (needs original default value) |
| `change_column` | ❌ Cannot infer (needs original type) |
| `enable_extension` | `disable_extension` |

If you call a non-reversible command inside `change`, Rails raises `ActiveRecord::IrreversibleMigration` at rollback time — **not** at migration time.

---

### In our project — where each was used and why

**`change` — used for all structural migrations:**

```ruby
# 20260322102554_create_projects.rb
def change
  create_table :projects do |t|
    t.string :name, null: false
    t.text :description
    t.timestamps
  end
end
```

`create_table` is fully reversible — Rails knows the reverse is `drop_table :projects`. Safe to use `change`.

```ruby
# 20260323144818_add_author_name_to_issues.rb
def change
  add_column :issues, :author_name, :string
end
```

`add_column` is reversible — Rails knows the reverse is `remove_column :issues, :author_name`. Safe to use `change`.

---

**`up`/`down` — used for the backfill migration:**

```ruby
# 20260323144942_backfill_author_name_on_issues.rb
def up
  issue_relation = define_model("issues", :author_name, :id)
  issue_relation.where(author_name: nil).in_batches(of: 1000) do |batch|
    batch.update_all(author_name: "unknown")
  end
end

def down
  # Reversing a backfill is a no-op — we don't want to re-NULL the column
end
```

A data backfill is **not a structural change** — it's a `UPDATE` statement. Rails has no mechanism to reverse arbitrary data manipulation. `up`/`down` is the only option, and `down` is intentionally a no-op because there's nothing meaningful to undo.

---

**`up`/`down` — used for the NOT NULL constraint migration:**

```ruby
# 20260323145039_add_not_null_to_issues_author_name.rb
def up
  change_column_null :issues, :author_name, false
end

def down
  change_column_null :issues, :author_name, true
end
```

`change_column_null` **is** reversible — Rails can infer the reverse. But we used `up`/`down` here for **clarity**: the migration has a comment block explaining the NOT VALID pattern alternative. When a migration is complex enough to warrant explanation, being explicit about both directions makes the intent clearer, even if `change` would technically work.

---

### When you MUST use `up`/`down`

#### 1. Data migrations (DML inside migrations)

```ruby
# Any INSERT, UPDATE, DELETE — Rails cannot reverse data changes
def up
  execute "UPDATE issues SET status = 1 WHERE status = 0 AND created_at < '2024-01-01'"
end

def down
  # Can't know which rows were changed — no-op or compensating update
end
```

#### 2. `remove_column` with existing data you care about

```ruby
# change would work for rollback syntax, but you'd lose the type info
# Being explicit is safer:
def up
  remove_column :issues, :legacy_field
end

def down
  add_column :issues, :legacy_field, :string, default: "n/a"
end
```

#### 3. `change_column` (type change)

```ruby
# change_column is NOT reversible — Rails doesn't know the original type
def up
  change_column :issues, :priority, :integer, using: "priority::integer"
end

def down
  change_column :issues, :priority, :string
end
```

#### 4. `drop_table`

```ruby
# drop_table in change works IF you supply the block (Rails stores the schema)
# But it's clearer and safer with up/down:
def up
  drop_table :legacy_tokens
end

def down
  create_table :legacy_tokens do |t|
    t.string :value, null: false
    t.references :user, foreign_key: true
    t.timestamps
  end
end
```

#### 5. `execute` with raw SQL

```ruby
# Raw SQL is always up/down — Rails has no idea what it does
def up
  execute "CREATE INDEX CONCURRENTLY ..."
end

def down
  execute "DROP INDEX ..."
end
```

#### 6. Custom logic / conditional migrations

```ruby
def up
  if column_exists?(:issues, :old_status)
    rename_column :issues, :old_status, :status
  else
    add_column :issues, :status, :integer, default: 0
  end
end

def down
  rename_column :issues, :status, :old_status
end
```

---

### The `reversible` escape hatch

When most of your `change` method is reversible but one part isn't, you can use `reversible` instead of splitting into `up`/`down`:

```ruby
def change
  add_column :issues, :priority, :integer, default: 0

  reversible do |dir|
    dir.up   { execute "UPDATE issues SET priority = 1 WHERE status = 'open'" }
    dir.down { } # no-op
  end

  add_index :issues, :priority
end
```

This keeps the migration readable while handling the non-reversible part explicitly.

---

### Decision guide

```text
Is every command in the migration on the "reversible" list above?
  YES → use change. Simple, concise, Rails handles rollback for you.
  NO  → use up/down, or use change + reversible block for the non-reversible parts.

Does the migration touch data (INSERT/UPDATE/DELETE)?
  YES → always use up/down. down is usually a no-op or compensating update.

Is the migration intentionally irreversible (e.g. dropping a column permanently)?
  YES → use up/down. In down, either raise ActiveRecord::IrreversibleMigration
        or leave it as a no-op with a comment explaining why.
```

Raising explicitly in `down` is better than a silent no-op when rollback truly isn't possible:

```ruby
def down
  raise ActiveRecord::IrreversibleMigration,
    "Cannot restore dropped data — restore from backup if needed"
end
```

---

#### Next up: Testing with RSpec / Minitest (Section 21)

---

## 21. Testing with RSpec — The GitLab Way

GitLab uses **RSpec** exclusively for backend testing (no Minitest). Their stack:

| Tool | Role |
| ---- | ---- |
| `rspec-rails` | Test framework |
| `factory_bot_rails` | Test data (factories, not fixtures) |
| `shoulda-matchers` | One-liner validation/association assertions |
| `database_cleaner-active_record` | DB isolation between tests |
| `capybara` + `selenium-webdriver` | System/feature specs |

### Gem setup

```ruby
# Gemfile
group :test do
  gem "rspec-rails"
  gem "factory_bot_rails"
  gem "shoulda-matchers"
  gem "database_cleaner-active_record"
  gem "capybara"
  gem "selenium-webdriver"
end
```

Bootstrap RSpec after installing:

```bash
bundle exec rails generate rspec:install
# Creates: .rspec, spec/spec_helper.rb, spec/rails_helper.rb
```

---

### `spec/rails_helper.rb` configuration

```ruby
require 'spec_helper'
require 'rspec/rails'
require 'shoulda/matchers'
require 'database_cleaner/active_record'

RSpec.configure do |config|
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  config.include FactoryBot::Syntax::Methods

  config.use_transactional_fixtures = false

  config.before(:suite) do
    DatabaseCleaner.strategy = :transaction
    DatabaseCleaner.clean_with(:truncation)
  end

  config.around(:each) do |example|
    DatabaseCleaner.cleaning { example.run }
  end
end

Shoulda::Matchers.configure do |config|
  config.integrate do |with|
    with.test_framework :rspec
    with.library :rails
  end
end
```

#### `config.infer_spec_type_from_file_location!`

RSpec needs to know what *type* of spec it is running so it can load the right helpers. Without this setting you would have to tag every single file manually:

```ruby
# without infer — you have to write this on every file
RSpec.describe Project, type: :model do …
RSpec.describe "Projects", type: :request do …
```

With `infer_spec_type_from_file_location!` RSpec reads the path and sets `type` automatically:

| File location | Inferred `type` | What it unlocks |
| --- | --- | --- |
| `spec/models/` | `:model` | ActiveRecord helpers |
| `spec/requests/` | `:request` | `get`, `post`, `response` helpers |
| `spec/controllers/` | `:controller` | `assigns`, `render_template` |
| `spec/helpers/` | `:helper` | view helper methods |
| `spec/system/` | `:system` | Capybara DSL |
| `spec/mailers/` | `:mailer` | mail delivery matchers |

**Practical effect**: you can write `RSpec.describe Project do` (no `type:`) and everything works as long as the file lives in the right folder. This matches GitLab's convention — no manual type tags.

#### `config.filter_rails_from_backtrace!`

When a test fails, Ruby prints a stack trace. Without this filter, the output includes dozens of internal Rails and gem frames that are irrelevant to your code:

```text
# Without filter_rails_from_backtrace!
Failure/Error: expect(project).to be_valid
  /Users/alins/.rbenv/gems/rspec-core-3.13/lib/rspec/core/example.rb:458:in `run'
  /Users/alins/.rbenv/gems/activerecord-8.1/lib/active_record/validations.rb:80:in `valid?'
  /Users/alins/.rbenv/gems/rspec-rails-8.0/lib/rspec/rails/matchers/be_valid.rb:14:in `matches?'
  spec/models/project_spec.rb:12:in `block (3 levels) in <top>'  # ← the line you care about
```

```text
# With filter_rails_from_backtrace!
Failure/Error: expect(project).to be_valid
  spec/models/project_spec.rb:12:in `block (3 levels) in <top>'  # ← only your code
```

Rails, RSpec, and gem frames are suppressed. You see only the lines inside your `spec/` directory. The full backtrace is still available via `--backtrace` flag if you need it.

#### `config.include FactoryBot::Syntax::Methods`

FactoryBot ships with two APIs:

```ruby
# Verbose API — always works, no config needed
FactoryBot.create(:project)
FactoryBot.build(:project)
FactoryBot.build_stubbed(:project)

# Shorthand API — requires config.include FactoryBot::Syntax::Methods
create(:project)
build(:project)
build_stubbed(:project)
```

`include FactoryBot::Syntax::Methods` mixes the shorthand methods into every RSpec example group so you can call `create` and `build` without the `FactoryBot.` prefix. This is the GitLab convention — all specs use the short form.

#### `config.use_transactional_fixtures`

This is the most important database-isolation setting and it interacts directly with DatabaseCleaner.

**`use_transactional_fixtures = true` (Rails default)**

Rails wraps each test in a database transaction and rolls it back after the test finishes. No data ever commits. The cycle looks like:

```sql
BEGIN;
  -- your test runs
ROLLBACK;
```

Advantages: very fast — no data actually hits disk between tests.

Disadvantages:

- Conflicts with DatabaseCleaner. Both systems try to own the transaction lifecycle and they fight each other — you get data leaking between specs or tests failing randomly.
- Does not work with system/feature specs that open a real browser (Capybara). The browser makes HTTP requests through a separate thread or process that cannot see the open transaction, so it sees an empty database even though your test inserted data.

**`use_transactional_fixtures = false` (our setting)**

Rails does not manage transactions at all. DatabaseCleaner takes over completely. This is required whenever you use DatabaseCleaner.

```sql
-- DatabaseCleaner.cleaning do
  BEGIN;
    -- your test runs
  ROLLBACK;
-- end
```

Each example is wrapped by the `around(:each)` hook. When `example.run` returns, DatabaseCleaner rolls back the transaction — the DB is empty again for the next test.

**Side effect to know**: primary key sequences (serial / bigserial in PostgreSQL) are NOT reset by a rollback. If you `create(:project)` in test 1 (ID = 1) and `create(:project)` in test 2 (ID = 2), the sequence keeps incrementing even though test 1's row was rolled back. **Never assert on a specific ID value** in a test. Use `project.id` rather than `1`.

#### `config.before(:suite)` — DatabaseCleaner setup

```ruby
config.before(:suite) do
  DatabaseCleaner.strategy = :transaction
  DatabaseCleaner.clean_with(:truncation)
end
```

This block runs **once** before the entire test suite starts. Two things happen:

**`DatabaseCleaner.strategy = :transaction`**

Sets the default cleanup strategy. `:transaction` means "wrap each example in a BEGIN/ROLLBACK". Alternatives:

| Strategy | How it cleans | Speed | When to use |
| --- | --- | --- | --- |
| `:transaction` | ROLLBACK | Fastest | Unit/request specs (our default) |
| `:truncation` | DELETE all rows from all tables | Slow | System/feature specs (browser) |
| `:deletion` | DELETE FROM each table | Moderate | Rarely — when truncation breaks triggers |

System specs that open a browser need `:truncation` because the browser runs in a separate thread. You can override the strategy for specific spec types:

```ruby
config.before(:each, type: :system) do
  DatabaseCleaner.strategy = :truncation
end
```

**`DatabaseCleaner.clean_with(:truncation)`**

Truncates every table once before the suite starts. This is a safety sweep — it wipes any data left over from a previous test run that crashed without cleaning up (e.g., you killed the process mid-run). `:truncation` is used here specifically because the suite hasn't started yet — there is no open transaction to roll back.

#### `config.around(:each)` — per-example cleaning

```ruby
config.around(:each) do |example|
  DatabaseCleaner.cleaning { example.run }
end
```

`around(:each)` runs a block for every single example. `DatabaseCleaner.cleaning` is a convenience wrapper that:

1. Starts a transaction (BEGIN)
2. Runs the example (`example.run`)
3. Rolls back (ROLLBACK)

Using `around(:each)` rather than separate `before` and `after` hooks has one key advantage: the rollback still happens even if the test raises an exception. A bare `after(:each)` hook can be skipped on error in some configurations.

The sequence for every spec:

```text
before(:suite)       ← once: set strategy, truncate
  around(:each)      ← BEGIN
    before(:each)    ← (any additional before hooks)
    ← example runs →
    after(:each)     ← (any additional after hooks)
  around(:each)      ← ROLLBACK
after(:suite)        ← (any suite-level teardown)
```

#### `Shoulda::Matchers.configure`

```ruby
Shoulda::Matchers.configure do |config|
  config.integrate do |with|
    with.test_framework :rspec
    with.library :rails
  end
end
```

Shoulda::Matchers is a separate gem. It needs to know two things:

**`with.test_framework :rspec`**

Tells Shoulda to include its matchers into RSpec example groups (rather than Minitest). Without this, calling `should validate_presence_of(:name)` raises `NoMethodError`.

Other valid values: `:minitest` (if you use Minitest).

**`with.library :rails`**

Loads all Rails-aware matchers: `validate_presence_of`, `validate_uniqueness_of`, `have_many`, `belong_to`, `have_db_column`, `permit_param`, etc. Without this only the basic Shoulda matchers load and all the ActiveRecord / ActiveModel matchers are missing.

You can scope it narrower if you only want part of Rails:

```ruby
with.library :active_record    # only DB/model matchers
with.library :active_model     # only validation matchers
with.library :action_controller # only controller matchers
```

The combination of `test_framework :rspec` + `library :rails` is the standard setup and is what GitLab would use.

---

### Directory layout

```text
spec/
  factories/          # FactoryBot definitions (one file per model)
    projects.rb
    issues.rb
    labels.rb
  models/             # Unit tests — fast, no HTTP
    project_spec.rb
    issue_spec.rb
    label_spec.rb
  requests/           # HTTP-level integration tests (GitLab preference over controller specs)
    projects_spec.rb
    issues_spec.rb
  support/            # Shared helpers, custom matchers, configs (auto-required)
  rails_helper.rb
  spec_helper.rb
```

GitLab uses `spec/` (not `test/`), `*_spec.rb` files (not `*_test.rb`).

---

### `# frozen_string_literal: true`

This is a **magic comment** that must appear on the very first line of a Ruby file (before any code, even `require` statements). It instructs the Ruby VM to freeze every string literal in that file at parse time.

#### What "frozen" means

In Ruby, strings are mutable objects by default — you can modify them in place:

```ruby
greeting = "hello"
greeting << " world"  # mutates the original string
puts greeting         # "hello world"
```

A frozen string raises `FrozenError` if you try to mutate it:

```ruby
greeting = "hello".freeze
greeting << " world"  # FrozenError: can't modify frozen String
```

#### What the magic comment does

```ruby
# frozen_string_literal: true

name = "Alice"
name << "!"  # FrozenError — same as calling "Alice".freeze explicitly
```

Every string literal in the file is treated as if `.freeze` was called on it. It does **not** affect strings built at runtime (e.g., string interpolation creates a new unfrozen string):

```ruby
# frozen_string_literal: true

base = "hello"
result = "#{base} world"  # fine — interpolation produces a new string object
```

#### Why Ruby (and GitLab) uses it

| Benefit | Detail |
| --- | --- |
| **Memory** | Identical frozen string literals can share the same object in memory. `"foo"` in 1000 files → 1 object instead of 1000. |
| **Performance** | The VM skips allocating a new String object each time the literal is evaluated — it reuses the frozen one. |
| **Safety** | Prevents accidental mutation of a string that is shared across multiple references (a subtle bug class). |
| **Ruby 3 direction** | The Ruby core team has long planned to make frozen string literals the default. Using the comment now is forward-compatible. |

GitLab's RuboCop ruleset enforces `frozen_string_literal: true` on every file via the `Style/FrozenStringLiteralComment` cop. That is why you see it at the top of every factory, spec, and model file in the project.

#### Running without it

If you omit the comment, strings are mutable (Ruby's current default). Your code still works — it is purely an optimisation and safety hint, not required for correctness.

---

### FactoryBot factories

Factories are the GitLab alternative to fixtures. One top-level factory per file, named after the model's plural.

```ruby
# spec/factories/projects.rb
FactoryBot.define do
  factory :project do
    sequence(:name) { |n| "Project #{n}" }  # unique across test run
    description { "A test project" }
  end
end

# spec/factories/issues.rb
FactoryBot.define do
  factory :issue do
    sequence(:title) { |n| "Issue #{n}" }
    status { :open }
    author_name { "Test Author" }
    association :project          # belongs_to wired automatically
  end
end

# spec/factories/labels.rb
FactoryBot.define do
  factory :label do
    sequence(:name) { |n| "Label #{n}" }
    color { "#ff0000" }

    trait :blue  { color { "#0000ff" } }  # traits keep factories lean
    trait :green { color { "#00ff00" } }
  end
end
```

**Key rules (from GitLab docs):**

- Only define attributes required for the record to be **valid** — nothing extra.
- Only supply attributes actually **needed by the test** when calling `create`.
- Use `association` (not `create`/`build` inside factories) for `belongs_to`.
- Use **traits** to vary behaviour, not multiple factory definitions.

**Factory methods and cost (slowest → fastest):**

```ruby
create(:project)         # Saves to DB — use only when persistence is needed
build(:project)          # In-memory, not saved — faster, use for unit tests
build_stubbed(:project)  # Fake AR object, no DB at all — fastest
attributes_for(:project) # Plain hash of attributes — for params
```

**When to use each:**

- Use `build` for validation tests — you only need the Ruby object to call `.valid?` and check `.errors`. No DB required.
- Use `create` when the test fires a real query (scopes, `find`, HTTP controller actions), tests `dependent: :destroy`, or checks associations that require persisted records.
- Never use `create` when `build` will do — every `create` is a DB write that slows the suite.

**Implicit association creation:**

```ruby
factory :issue do
  association :project   # belongs_to
end
```

When you call `create(:issue)` without passing a project, FactoryBot automatically calls `create(:project)` behind the scenes. This is convenient but can create many hidden DB records at scale — which is why GitLab uses `FactoryDefault` and `let_it_be` to share parent objects across examples.

---

### Model specs

**GitLab conventions:**

- Single top-level `RSpec.describe ClassName` (no `do ... end` nesting outside it).
- Use `.method` for class methods, `#method` for instance methods in descriptions.
- Use `context` for branching logic ("when X", "with Y").
- Use `described_class` instead of hardcoding the class name.
- `subject` for the thing under test; avoid anonymous `subject` — use named subjects.

```ruby
# spec/models/project_spec.rb
RSpec.describe Project do
  # Shoulda::Matchers — one-liner assertions
  describe 'associations' do
    it { is_expected.to have_many(:issues).dependent(:destroy) }
  end

  describe 'validations' do
    it { is_expected.to validate_presence_of(:name) }
    it { is_expected.to validate_length_of(:name).is_at_most(255) }
  end

  describe 'factory' do
    it 'has a valid factory' do
      expect(build(:project)).to be_valid
    end
  end

  describe 'dependent: :destroy' do
    let(:project) { create(:project) }
    let!(:issue)  { create(:issue, project: project) }   # let! = eager, created before example

    it 'destroys associated issues when deleted' do
      expect { project.destroy }.to change(Issue, :count).by(-1)
    end
  end
end
```

---

### `let` vs `let!` vs `let_it_be`

| Helper | Created | Shared between examples? | GitLab recommendation |
| ------ | ------- | ------------------------ | --------------------- |
| `let` | Lazily, on first reference | No (new each example) | Default choice |
| `let!` | Eagerly, before each example | No (new each example) | When side effects must happen before `it` |
| `let_it_be` | Once, before all examples in context | Yes (read-only) | GitLab default for DB objects (needs `test-prof` gem) |
| `let_it_be_with_reload` | Once | Yes, reloaded after each | When the example modifies the object |

At GitLab's scale, `let_it_be` (from the [`test-prof`](https://github.com/test-prof/test-prof) gem) dramatically speeds up tests by creating DB objects once per context instead of once per example. For this app, plain `let` is fine.

---

### Enum specs

```ruby
describe 'status enum' do
  subject(:issue) { build(:issue) }

  it 'defaults to open' do
    expect(issue.status).to eq('open')
  end

  it 'raises on an invalid value' do
    expect { issue.status = :unknown }.to raise_error(ArgumentError)
  end

  context 'when set to closed' do
    let(:persisted_issue) { create(:issue) }

    before { persisted_issue.closed! }  # bang method persists, needs DB

    it 'is closed' do
      expect(persisted_issue).to be_closed
    end
  end
end
```

**Note:** Test enum **behaviour** (predicates, transitions) not constant values. Testing that `Issue.statuses[:open] == 0` just duplicates the code.

---

### Scope specs

```ruby
describe '.recent' do
  let(:project) { create(:project) }

  it 'orders issues by created_at descending' do
    older = create(:issue, project: project, created_at: 2.days.ago)
    newer = create(:issue, project: project, created_at: 1.day.ago)

    expect(Issue.recent).to eq([newer, older])
  end
end

describe '.with_labels' do
  it 'eager loads labels to avoid N+1 queries' do
    result = Issue.with_labels.find(issue.id)

    # Assert association is already loaded — no extra query fired
    expect(result.association(:labels)).to be_loaded
  end
end
```

---

### Request specs (GitLab's preferred integration test)

GitLab uses **request specs** over controller specs. Request specs exercise the full stack: routing → middleware → controller → response.

```ruby
# spec/requests/projects_spec.rb
RSpec.describe 'Projects', type: :request do
  let(:project) { create(:project) }

  describe 'GET /projects' do
    it 'returns HTTP 200' do
      get projects_path

      expect(response).to have_http_status(:ok)
    end
  end

  describe 'POST /projects' do
    context 'with valid parameters' do
      let(:valid_params) { { project: { name: 'My Project' } } }

      it 'creates a new project' do
        expect { post projects_path, params: valid_params }.to change(Project, :count).by(1)
      end

      it 'redirects to the new project' do
        post projects_path, params: valid_params

        expect(response).to redirect_to(project_path(Project.last))
      end
    end

    context 'with invalid parameters' do
      it 'returns HTTP 422' do
        post projects_path, params: { project: { name: '' } }

        expect(response).to have_http_status(:unprocessable_content)
      end
    end
  end

  describe 'DELETE /projects/:id' do
    it 'destroys the project' do
      project_to_delete = create(:project)

      expect { delete project_path(project_to_delete) }.to change(Project, :count).by(-1)
    end
  end
end
```

**Do not use** `render_template` in request specs — that requires the `rails-controller-testing` gem which GitLab discourages. Assert on status codes and response body content instead.

---

### Shoulda::Matchers cheatsheet

```ruby
# Associations
it { is_expected.to belong_to(:project) }
it { is_expected.to have_many(:issues).dependent(:destroy) }
it { is_expected.to have_many(:labels).through(:issue_labels) }

# Validations
it { is_expected.to validate_presence_of(:name) }
it { is_expected.to validate_length_of(:name).is_at_most(255) }
it { is_expected.to validate_uniqueness_of(:email) }
it { is_expected.to validate_numericality_of(:position).is_greater_than(0) }
```

These replace verbose multi-line tests and are highly readable in diffs.

---

### Four-Phase Test pattern

GitLab follows the [Four-Phase Test](https://thoughtbot.com/blog/four-phase-test) pattern with blank lines separating phases:

```ruby
it 'removes the issue from the project' do
  # Setup
  project = create(:project)
  issue   = create(:issue, project: project)

  # Exercise
  issue.destroy

  # Verify
  expect(project.issues.reload).to be_empty

  # Teardown — handled automatically by DatabaseCleaner
end
```

---

### Running specs

```bash
bundle exec rspec                           # run all specs
bundle exec rspec spec/models/project_spec.rb        # single file
bundle exec rspec spec/models/project_spec.rb:45     # specific line
bundle exec rspec spec/models/ spec/requests/        # multiple dirs
bundle exec rspec --format documentation             # verbose output
bundle exec rspec --profile                          # show 10 slowest examples
```

---

### Interview Q&A

**Q: Why RSpec over Minitest?**
RSpec's DSL (`describe`/`context`/`it`) reads like a specification, making test intent clear at a glance. GitLab chose it for its expressiveness, rich matcher library, shared examples, and metadata system (tags like `:js`, `:sidekiq_inline`). Minitest is faster to boot but harder to read at scale.

**Q: Why FactoryBot over fixtures?**
Fixtures are static YAML — they don't adapt to schema changes, they ignore validations, and they load all data regardless of what the test needs. FactoryBot creates only what the test requires, respects validations, supports traits for variations, and is far easier to maintain.

**Q: What's the difference between `build` and `create`?**
`build` constructs an in-memory object without touching the DB. `create` persists it. Use `build` whenever you don't need DB persistence — it's faster and reduces coupling. Use `create` when the test exercises DB queries, associations, or scopes.

**Q: Why use DatabaseCleaner with the transaction strategy?**
Each test runs inside a DB transaction that is rolled back at the end. This is faster than truncating tables and restores the DB to a pristine state without resetting sequences. The downside: since primary key sequences aren't reset, you must never assert on specific ID values.

**Q: What's `let_it_be` and when would you use it?**
`let_it_be` (from the `test-prof` gem) creates a DB record once for all examples in a context, rather than once per example like `let`. After each example, changes are rolled back, and the object is reloaded. At GitLab's scale this dramatically reduces DB writes. Use it for objects that don't change between examples; use `let_it_be_with_reload` if the example modifies the object.

**Q: Request spec vs controller spec — what's the difference?**
Controller specs bypass routing and middleware, hitting the controller action directly. Request specs go through the full Rack stack (routing → middleware → controller → view → response). GitLab deprecated controller specs in favour of request specs because request specs give higher confidence and closer match to real HTTP behaviour.

---

## 22. Ruby Particularities — Truthiness, Identity & Gotchas

Ruby's rules are simple but different enough from other languages to trip you up in an interview.

---

### Truthiness — what is truthy and what is falsy?

Ruby has exactly **two falsy values**: `nil` and `false`. Everything else is truthy — no exceptions.

| Value | Truthy? | Notes |
| --- | --- | --- |
| `nil` | **falsy** | The only "nothing" value in Ruby |
| `false` | **falsy** | The boolean false |
| `0` | **truthy** | Unlike C, JavaScript, Python |
| `0.0` | **truthy** | Same — all numbers are truthy |
| `""` | **truthy** | Unlike Python — empty string is truthy |
| `"0"` | **truthy** | A non-empty string |
| `[]` | **truthy** | Unlike Python — empty array is truthy |
| `{}` | **truthy** | Unlike Python — empty hash is truthy |
| `true` | truthy | |
| Any object | truthy | Including `0`, `""`, `[]`, `{}` |

```ruby
puts "truthy" if 0        # prints "truthy"
puts "truthy" if ""       # prints "truthy"
puts "truthy" if []       # prints "truthy"
puts "truthy" if {}       # prints "truthy"
puts "truthy" if "false"  # prints "truthy" — it's a non-empty string!

puts "truthy" if nil      # nothing — nil is falsy
puts "truthy" if false    # nothing — false is falsy
```

**Interview tip**: JavaScript developers get burned by `0` and `""` being falsy in JS but truthy in Ruby. Python developers get burned by `[]` and `{}` being falsy in Python but truthy in Ruby.

---

### `nil?`, `blank?`, `present?`, `empty?`

Ruby and Rails offer several ways to check "emptiness" — they are not the same:

| Method | Defined by | Returns true when |
| --- | --- | --- |
| `nil?` | Ruby (all objects) | only if the receiver IS `nil` |
| `empty?` | Ruby (String, Array, Hash) | collection has zero elements |
| `blank?` | Rails (ActiveSupport) | `nil`, `false`, whitespace-only string, empty collection |
| `present?` | Rails (ActiveSupport) | opposite of `blank?` |

```ruby
nil.nil?        # => true
"".nil?         # => false   ← "" is NOT nil
0.nil?          # => false

"".empty?       # => true
[].empty?       # => true
" ".empty?      # => false   ← space is not empty

nil.blank?      # => true
false.blank?    # => true
"".blank?       # => true
"  ".blank?     # => true    ← whitespace-only is blank
[].blank?       # => true
0.blank?        # => false   ← 0 is NOT blank
"hi".blank?     # => false

nil.present?    # => false
"hi".present?   # => true
"  ".present?   # => false   ← whitespace-only is not present
```

**When to use which:**

- `nil?` — you specifically want to check for `nil` and nothing else
- `empty?` — pure Ruby, no Rails dependency, you know the type is a String/Array/Hash
- `blank?` — Rails code where the value could be `nil`, `false`, or a whitespace string (e.g., form params)
- `present?` — common guard in controllers: `if params[:query].present?`

---

### `==`, `eql?`, `equal?` — value equality vs object identity

Ruby has three equality methods and they mean different things:

| Method | Checks | Example |
| --- | --- | --- |
| `==` | Value equality (can be overridden) | `1 == 1.0` → `true` |
| `eql?` | Value equality without type coercion | `1.eql?(1.0)` → `false` |
| `equal?` | Object identity — same memory address | `"a".equal?("a")` → `false` |

```ruby
1 == 1.0        # true  — Integer and Float compare equal by value
1.eql?(1.0)     # false — different types, no coercion
1.equal?(1)     # true  — small integers are cached (same object)

"hello" == "hello"      # true  — same content
"hello".eql?("hello")   # true  — same content, same type
"hello".equal?("hello") # false — two different String objects in memory
```

`equal?` is essentially `object_id ==` and should almost never be used for business logic.

---

### `&&` / `||` vs `and` / `or`

Ruby has two sets of boolean operators. They behave identically as conditionals but have **very different operator precedence**:

```ruby
# && / || have higher precedence than assignment
x = true && false   # x = (true && false) → x = false

# and / or have lower precedence than assignment
x = true and false  # (x = true) and false → x = true  ← surprising!
```

**Rule**: use `&&` and `||` for conditions. `and` / `or` are control-flow words used idiomatically in patterns like:

```ruby
result = find_record or raise "not found"
do_something and return
```

GitLab's RuboCop config bans `and` / `or` in conditions via `Style/AndOr`. Always use `&&` / `||`.

---

### Safe navigation operator `&.`

Introduced in Ruby 2.3. Calls the method only if the receiver is not `nil`; returns `nil` otherwise:

```ruby
user = nil
user.name         # NoMethodError: undefined method `name' for nil
user&.name        # => nil — no error

user = User.new(name: "Alice")
user&.name        # => "Alice"
```

Replaces the common Rails guard pattern:

```ruby
# old
user && user.name

# new
user&.name
```

Chainable:

```ruby
user&.address&.city   # nil if user or address is nil
```

**When not to use it**: `&.` silently swallows `nil`. If `nil` should be impossible at that point in the code, let it raise `NoMethodError` so the bug surfaces immediately.

---

### Symbols vs Strings

| Property | Symbol | String |
| --- | --- | --- |
| Mutability | Immutable | Mutable (unless frozen) |
| Memory | One object per name — `:foo` is always the same object | Each `"foo"` literal is a new object |
| Use case | Hash keys, method names, identifiers | User-facing text, data |

```ruby
:name.object_id == :name.object_id    # => true  — same object always
"name".object_id == "name".object_id  # => false — two distinct objects

:hello.to_s     # => "hello"
"hello".to_sym  # => :hello
```

Rails hashes often accept both — `ActionController::Parameters` is a `HashWithIndifferentAccess`:

```ruby
params[:name]   # works
params["name"]  # also works
```

---

### `||=` — conditional assignment and memoization

Assigns only if the variable is `nil` or `false`:

```ruby
x = nil
x ||= "default"      # x = "default"

x = "already set"
x ||= "default"      # x = "already set" — not reassigned

x = false
x ||= "default"      # x = "default" — false is also falsy!
```

Common Rails memoization pattern:

```ruby
def current_user
  @current_user ||= User.find_by(id: session[:user_id])
end
```

The DB is only hit on the first call. **Gotcha**: if `find_by` returns `nil`, `@current_user` stays `nil` and the DB is hit again every call. Use `defined?` to cache `nil` explicitly:

```ruby
def current_user
  return @current_user if defined?(@current_user)
  @current_user = User.find_by(id: session[:user_id])
end
```

---

### `Integer()` vs `.to_i` — strict vs lenient conversion

```ruby
"42".to_i        # => 42
"abc".to_i       # => 0    ← silent fallback
"42abc".to_i     # => 42   ← stops at first non-digit

Integer("42")    # => 42
Integer("abc")   # ArgumentError: invalid value for Integer(): "abc"
Integer("42abc") # ArgumentError — strict, no partial parse
```

Use `Integer()` when bad input should raise (e.g., validating a user-supplied ID). Use `.to_i` only when a `0` fallback is acceptable. The same pattern applies to `Float()` vs `.to_f`.

---

### `respond_to?` and duck typing

Ruby uses duck typing — you call methods on objects without checking their class. `respond_to?` checks capability before invoking:

```ruby
def serialize(obj)
  if obj.respond_to?(:to_json)
    obj.to_json
  else
    obj.to_s
  end
end
```

Preferred over `is_a?` because it works with any object that has the right interface regardless of inheritance. A `File`, a `StringIO`, and a custom class can all respond to `#read` — `respond_to?(:read)` accepts all three; `is_a?(IO)` rejects the custom class.

---

### `method_missing` and `respond_to_missing?`

When you call a method that doesn't exist, Ruby calls `method_missing` before raising `NoMethodError`. This is how Rails dynamic finders and `OpenStruct` work:

```ruby
class FlexibleConfig
  def initialize(data)
    @data = data
  end

  def method_missing(name, *args)
    key = name.to_s
    @data.key?(key) ? @data[key] : super
  end

  def respond_to_missing?(name, include_private = false)
    @data.key?(name.to_s) || super
  end
end

config = FlexibleConfig.new("timeout" => 30)
config.timeout               # => 30
config.respond_to?(:timeout) # => true — because of respond_to_missing?
```

**Always define `respond_to_missing?` alongside `method_missing`** — otherwise `respond_to?` returns `false` for methods you handle, breaking contracts other code relies on.

---

### `Comparable` and `<=>` (spaceship operator)

`<=>` returns `-1`, `0`, or `1` (or `nil` if not comparable):

```ruby
1 <=> 2     # => -1
2 <=> 2     # => 0
3 <=> 2     # => 1
"a" <=> "b" # => -1
```

`Array#sort` uses `<=>` internally. Include `Comparable` in a class and define `<=>` to get `<`, `>`, `<=`, `>=`, `between?`, and `clamp` for free:

```ruby
class Priority
  include Comparable
  attr_reader :level
  def initialize(level) = @level = level
  def <=>(other) = level <=> other.level
end

low  = Priority.new(1)
high = Priority.new(3)
low < high    # => true
high > low    # => true
[high, low].sort  # => [low, high]
```

---

### Ruby Particularities — Interview Q&A

**Q: Is `0` truthy in Ruby?**
Yes. Only `nil` and `false` are falsy. Every other object — including `0`, `""`, `[]`, `{}` — is truthy. This is a deliberate design choice and differs from JavaScript, Python, and C.

**Q: What's the difference between `blank?` and `nil?`?**
`nil?` returns `true` only for `nil`. `blank?` (Rails/ActiveSupport) returns `true` for `nil`, `false`, empty strings, whitespace-only strings, and empty collections. Use `nil?` when you specifically want to detect `nil`; use `blank?` in Rails controllers and models where the value might be any of those "nothing useful" cases.

**Q: What does `||=` do and what's its gotcha?**
`x ||= value` assigns `value` to `x` only if `x` is currently `nil` or `false`. First gotcha: `false` is also replaced, which can be surprising. Second gotcha: if the right-hand side has a side effect (like a DB query that returns `nil`), that side effect fires every call when the cached value is `nil`. Solve the second with `return @var if defined?(@var)`.

**Q: What's the difference between `==`, `eql?`, and `equal?`?**
`==` is value equality and can be overridden — `1 == 1.0` is `true`. `eql?` is value equality without type coercion — `1.eql?(1.0)` is `false`. `equal?` is object identity (same `object_id`) — almost never useful for business logic.

**Q: When would you use `respond_to?` over `is_a?`?**
`is_a?` checks the class hierarchy. `respond_to?` checks capability — whether the object can handle a message. Duck typing prefers capability: `respond_to?(:read)` accepts any readable object regardless of class, while `is_a?(IO)` rejects anything not in the IO hierarchy.

**Q: What happens if you define `method_missing` but not `respond_to_missing?`?**
`respond_to?(:that_method)` returns `false` even though you handle it. Code that checks `respond_to?` before calling (a common defensive pattern) will skip your handler. Always pair them.

---

## 23. Multi-Format Responses — `respond_to` and the JSON API Pattern

Rails controllers can serve HTML and JSON (or any other format) from the same action using `respond_to`. This is the foundation of building an app that works as both a traditional web UI and an API.

---

### How Rails decides which format to serve

Rails inspects two things in the incoming request, in priority order:

1. **The `Accept` header** — sent by the client: `Accept: application/json`
2. **The format suffix in the URL** — `/issues/1.json` vs `/issues/1`

If neither is specified, Rails defaults to HTML. If the client requests a format the action doesn't handle, Rails raises `ActionController::UnknownFormat` (406 Not Acceptable).

---

### `respond_to` — the core API

```ruby
def show
  respond_to do |format|
    format.html           # no block = render the default template (show.html.erb)
    format.json { render json: @issue }
  end
end
```

The block passed to `format.json` is only executed when the request asks for JSON. The block passed to `format.html` is optional — omitting it tells Rails to render the matching view template as usual.

---

### Full CRUD pattern with HTML + JSON

```ruby
class IssuesController < ApplicationController
  before_action :set_issue, only: %i[show edit update destroy]

  # GET /issues/1
  # GET /issues/1.json
  def show
    respond_to do |format|
      format.html           # → app/views/issues/show.html.erb
      format.json { render json: @issue }
    end
  end

  # POST /issues
  # POST /issues.json
  def create
    @issue = @project.issues.new(issue_params)

    respond_to do |format|
      if @issue.save
        format.html { redirect_to @issue, notice: "Issue was successfully created." }
        format.json { render json: @issue, status: :created, location: @issue }
      else
        format.html { render :new, status: :unprocessable_content }
        format.json { render json: @issue.errors, status: :unprocessable_content }
      end
    end
  end

  # PATCH /issues/1
  # PATCH /issues/1.json
  def update
    respond_to do |format|
      if @issue.update(issue_params)
        format.html { redirect_to @issue, notice: "Issue was successfully updated." }
        format.json { render json: @issue }
      else
        format.html { render :edit, status: :unprocessable_content }
        format.json { render json: @issue.errors, status: :unprocessable_content }
      end
    end
  end

  # DELETE /issues/1
  # DELETE /issues/1.json
  def destroy
    @issue.destroy!

    respond_to do |format|
      format.html { redirect_to issues_path, notice: "Issue was successfully deleted." }
      format.json { head :no_content }  # 204 — success with no body
    end
  end
end
```

---

### What each JSON response looks like

| Action | Success status | Success body | Failure status | Failure body |
| --- | --- | --- | --- | --- |
| `show` | 200 OK | `{ id: 1, title: "...", ... }` | — | — |
| `create` | 201 Created | the new record as JSON | 422 | `{ title: ["can't be blank"] }` |
| `update` | 200 OK | the updated record as JSON | 422 | `{ title: ["is too long"] }` |
| `destroy` | 204 No Content | (empty body) | — | — |

**Why `head :no_content` for destroy?** The resource no longer exists — there is nothing to render. HTTP 204 tells the client the operation succeeded but there is no body. Sending `render json: {}` would also work but is non-standard.

**Why `location: @issue` on create?** The `Location` HTTP header tells the client where the newly created resource lives (`/issues/1`). This is required by the HTTP spec for 201 responses.

---

### `render json:` internals

`render json: @issue` calls `@issue.to_json` under the hood. By default ActiveRecord serialises all columns. You can control the output:

```ruby
# exclude sensitive columns
render json: @issue.to_json(except: [:created_at, :updated_at])

# include associations
render json: @issue.to_json(include: :labels)

# custom shape with as_json
render json: @issue.as_json(only: [:id, :title, :status])

# or use a serializer gem (Jbuilder, ActiveModelSerializers, JSONAPI::Serializer)
```

GitLab uses Grape + custom entity classes for its REST API, but in plain Rails the Jbuilder view pattern (`.json.jbuilder` templates) or a serializer gem is the idiomatic choice for complex shapes.

---

### Enabling JSON in routes

Routes don't need to change — Rails handles format negotiation automatically. But you can make format suffixes explicit with:

```ruby
# config/routes.rb
resources :issues, defaults: { format: :json }  # always JSON unless told otherwise
# or
resources :issues, constraints: { format: /json|html/ }
```

Most apps leave routes as-is and rely on the `Accept` header.

---

### Testing multi-format actions in request specs

```ruby
# spec/requests/issues_spec.rb

describe "GET /issues/:id" do
  let(:issue) { create(:issue) }

  context "HTML request" do
    it "returns 200" do
      get issue_path(issue)
      expect(response).to have_http_status(:ok)
    end
  end

  context "JSON request" do
    it "returns the issue as JSON" do
      get issue_path(issue), headers: { "Accept" => "application/json" }

      expect(response).to have_http_status(:ok)
      expect(response.content_type).to include("application/json")

      json = JSON.parse(response.body)
      expect(json["id"]).to eq(issue.id)
      expect(json["title"]).to eq(issue.title)
    end
  end
end

describe "POST /issues (JSON)" do
  let(:project) { create(:project) }

  context "with valid params" do
    it "creates the issue and returns 201" do
      post project_issues_path(project),
           params: { issue: { title: "New issue", author_name: "Alice" } },
           headers: { "Accept" => "application/json" }

      expect(response).to have_http_status(:created)
      expect(response.headers["Location"]).to be_present
    end
  end

  context "with invalid params" do
    it "returns 422 and the errors hash" do
      post project_issues_path(project),
           params: { issue: { title: "" } },
           headers: { "Accept" => "application/json" }

      expect(response).to have_http_status(:unprocessable_content)
      json = JSON.parse(response.body)
      expect(json["title"]).to include("can't be blank")
    end
  end
end
```

---

### Multi-Format Responses — Interview Q&A

**Q: How does Rails decide which format to render?**
It checks the `Accept` request header first, then the URL suffix (`.json`, `.html`). If neither is present, it defaults to HTML. If the client requests a format the action doesn't handle, Rails responds with 406 Not Acceptable.

**Q: What happens if you call `respond_to` but omit a `format.json` block and the client sends `Accept: application/json`?**
Rails raises `ActionController::UnknownFormat`, which results in a 406 response. Always declare every format you want to support.

**Q: Why use `head :no_content` instead of `render json: {}` on destroy?**
HTTP semantics: 204 No Content means the operation succeeded and there is no body to parse. It is the correct status for a successful DELETE. Returning `{}` with 200 is technically wrong because the body implies there is content.

**Q: How do you customise what gets serialised to JSON?**
`render json:` calls `to_json` on the object. You can pass `only:`, `except:`, and `include:` options to `as_json` / `to_json`, or use a dedicated serialiser — Jbuilder (view templates), ActiveModelSerializers, or JSONAPI::Serializer — for more complex shapes.

---

## 24. Jbuilder — JSON View Templates

Jbuilder is a DSL gem (shipped with Rails by default) that lets you build JSON responses in dedicated view files instead of inline `render json:` calls in the controller. The template naming follows the same convention as ERB: `app/views/<controller>/<action>.json.jbuilder`.

---

### Why Jbuilder over `render json:`

| | `render json: @record` | Jbuilder template |
| --- | --- | --- |
| Where presentation logic lives | Controller | View (correct layer) |
| Field control | `as_json` options scattered in controller | Explicit, one field per line |
| Nested associations | `include:` chains get unwieldy | `json.key collection { }` reads clearly |
| Reuse | Duplicated across actions | Extract shared partials (`_issue.json.jbuilder`) |
| Accidental data leaks | Easy — all columns by default | Hard — you list every field explicitly |

---

### How Rails finds the template

When `format.json` has **no block**, Rails looks for a view template matching the action and format:

```ruby
# controller
def show
  respond_to do |format|
    format.html           # → show.html.erb
    format.json           # → show.json.jbuilder  (no block needed)
  end
end
```

If a block IS provided (`format.json { render json: @issue }`), the block takes priority and no template is consulted.

---

### Core Jbuilder methods

#### `json.key value` — set a single field

```ruby
json.id    @issue.id       # "id": 1
json.title @issue.title    # "title": "Login broken"
```

#### `json.extract! object, :field1, :field2` — pull multiple fields at once

```ruby
json.extract! @issue, :id, :title, :status, :author_name, :created_at
# equivalent to writing json.id / json.title / etc. individually
```

#### `json.key object, :field1, :field2` — extract fields under a key

```ruby
json.project @issue.project, :id, :name
# "project": { "id": 1, "name": "My Project" }
```

#### `json.array! collection { }` — root-level array

```ruby
json.array! @issues do |issue|
  json.extract! issue, :id, :title, :status
end
# [ { "id": 1, ... }, { "id": 2, ... } ]
```

#### `json.key collection { }` — nested array under a key

```ruby
json.labels @issue.labels do |label|
  json.extract! label, :id, :name, :color
end
# "labels": [ { "id": 1, "name": "bug", "color": "#ff0000" } ]
```

#### `json.key do … end` — nested object

```ruby
json.project do
  json.id   @issue.project.id
  json.name @issue.project.name
  json.url  project_url(@issue.project)
end
# "project": { "id": 1, "name": "...", "url": "..." }
```

#### `json.url` — route helpers work directly

```ruby
json.url project_url(@project)    # full URL: "http://localhost:3000/projects/1"
json.path project_path(@project)  # path only: "/projects/1"
```

---

### Real templates from this project

#### `app/views/projects/index.json.jbuilder`

```ruby
json.array! @projects do |project|
  json.id          project.id
  json.name        project.name
  json.description project.description
  json.created_at  project.created_at
  json.updated_at  project.updated_at
  json.url         project_url(project)
end
```

Output for `GET /projects.json`:

```json
[
  {
    "id": 1,
    "name": "Potato App",
    "description": "A learning project",
    "created_at": "2026-03-25T10:00:00.000Z",
    "updated_at": "2026-03-25T10:00:00.000Z",
    "url": "http://localhost:3000/projects/1"
  }
]
```

#### `app/views/projects/show.json.jbuilder`

```ruby
json.id          @project.id
json.name        @project.name
json.description @project.description
json.created_at  @project.created_at
json.url         project_url(@project)

json.issues @project.issues.recent do |issue|
  json.id          issue.id
  json.title       issue.title
  json.status      issue.status
  json.author_name issue.author_name
  json.created_at  issue.created_at
  json.url         issue_url(issue)

  json.labels issue.labels do |label|
    json.extract! label, :id, :name, :color
  end
end
```

Output for `GET /projects/1.json`:

```json
{
  "id": 1,
  "name": "Potato App",
  "description": "A learning project",
  "created_at": "2026-03-25T10:00:00.000Z",
  "url": "http://localhost:3000/projects/1",
  "issues": [
    {
      "id": 3,
      "title": "Login broken",
      "status": "open",
      "author_name": "Alice",
      "created_at": "2026-03-25T11:00:00.000Z",
      "url": "http://localhost:3000/issues/3",
      "labels": [
        { "id": 1, "name": "bug", "color": "#ff0000" }
      ]
    }
  ]
}
```

#### `app/views/issues/show.json.jbuilder`

```ruby
json.id          @issue.id
json.title       @issue.title
json.description @issue.description
json.status      @issue.status
json.author_name @issue.author_name
json.created_at  @issue.created_at
json.updated_at  @issue.updated_at
json.url         issue_url(@issue)

json.labels @issue.labels do |label|
  json.extract! label, :id, :name, :color
end

json.project do
  json.id   @issue.project.id
  json.name @issue.project.name
  json.url  project_url(@issue.project)
end
```

---

### Shared partials — avoiding repetition

When the same JSON shape appears in multiple templates, extract it to a partial. Rails partial naming for Jbuilder follows the same `_name.json.jbuilder` convention:

```ruby
# app/views/issues/_issue.json.jbuilder
json.extract! issue, :id, :title, :status, :author_name, :created_at
json.url issue_url(issue)
```

Then render it from any template:

```ruby
# app/views/projects/show.json.jbuilder
json.issues @project.issues do |issue|
  json.partial! "issues/issue", issue: issue
end

# app/views/issues/index.json.jbuilder
json.array! @issues, partial: "issues/issue", as: :issue
```

---

### N+1 awareness with Jbuilder

Jbuilder templates iterate over associations. If those associations aren't preloaded, every iteration fires a new query. Always eager-load in the controller before passing data to the template:

```ruby
# controller — preload before the template iterates
def show
  @project = Project.includes(issues: :labels).find(params[:id])
  respond_to do |format|
    format.html
    format.json
  end
end
```

Without `includes(issues: :labels)`, the `show.json.jbuilder` template above would fire:

- 1 query for the project
- 1 query per issue to load labels → N+1

---

### Jbuilder — Interview Q&A

**Q: What is Jbuilder and why use it?**
Jbuilder is a Rails-bundled DSL for building JSON responses as view templates (`.json.jbuilder` files). It keeps JSON presentation logic in the view layer where it belongs, gives you explicit control over which fields are exposed, and supports partials for reuse — unlike `render json:` which serialises everything by default and clutters the controller.

**Q: How does Rails know to use a Jbuilder template?**
When `format.json` in `respond_to` has no block, Rails looks for `app/views/<controller>/<action>.json.jbuilder` — exactly the same lookup as ERB templates. If a block is provided, the block wins and no template is consulted.

**Q: What's `json.extract!` and when do you use it?**
`json.extract! object, :field1, :field2` is shorthand for writing `json.field1 object.field1` etc. individually. Use it when you want to expose several fields from the same object without customising the keys — it's more concise. If you need to rename keys or transform values, write them out individually instead.

**Q: How do you avoid N+1 queries in Jbuilder templates?**
Jbuilder templates iterate over associations lazily — if the association isn't loaded, ActiveRecord fires a query per record. The fix is the same as everywhere else in Rails: eager-load with `includes` in the controller action before the template renders.

```ruby
# In the controller action:
@issues = @project.issues.includes(:labels).recent
```

---

## 25. Where Logic Lives — Model, Controller, Service Object & Beyond

One of the most common interview topics — and one of the most common code-review flashpoints — is *separation of concerns*: which layer of a Rails app should own which kind of logic? This section covers the Rails convention, the GitLab engineering standard (sourced directly from [docs.gitlab.com/development/software_design](https://docs.gitlab.com/development/software_design/) and the GitLab engineering handbook), and how those rules play out in this project.

---

### The core principle: each layer has one job

> "Design software around use-cases, not entities." — GitLab Software Design Guide

Rails gives you MVC. In practice, real apps need more layers. Here is the complete picture:

| Layer | Location | Owns |
| --- | --- | --- |
| Model | `app/models/` | Persistence, validations, associations, scopes, domain invariants |
| Controller | `app/controllers/` | HTTP request/response cycle — nothing else |
| Service Object | `app/services/` | A single, named business use-case |
| Worker (Sidekiq) | `app/workers/` | Async/background execution of a service or side-effect |
| Presenter / Decorator | `app/presenters/` | View-layer formatting; keeps models and views clean |
| Policy | `app/policies/` | Authorization — who can do what |
| Serializer / Jbuilder | `app/serializers/`, `app/views/*.json.jbuilder` | JSON representation |
| Validator | `app/validators/` | Reusable, cross-model validation logic |
| Form Object | `app/forms/` | Multi-model form submission logic |
| Query Object | `app/finders/` | Complex database queries extracted from models |

---

### The Model — domain rules only

The model is responsible for **data and invariants**. It should know nothing about HTTP, nothing about the current user session, and nothing about how data is rendered.

**What belongs in the model:**

```ruby
class Issue < ApplicationRecord
  # ✅ Associations — model owns its relationships
  belongs_to :project
  has_many :issue_labels, dependent: :destroy
  has_many :labels, through: :issue_labels

  # ✅ Enums — domain concept
  enum :status, { open: 0, in_progress: 1, closed: 2 }

  # ✅ Validations — guard the domain invariant
  validates :title, presence: true, length: { maximum: 255 }, no_profanity: true
  validates :author_name, presence: true
  validate :author_name_cannot_contain_digits

  # ✅ Scopes — named, reusable query fragments
  scope :recent,      -> { order(created_at: :desc) }
  scope :by_status,   ->(status) { where(status: status) }
  scope :with_labels, -> { includes(:labels) }

  private

  # ✅ Domain rule expressed as a method
  def author_name_cannot_contain_digits
    return if author_name.blank?
    errors.add(:author_name, "cannot contain numbers") if author_name.match?(/\d/)
  end
end
```

**What does NOT belong in the model:**

```ruby
# ❌ HTTP / session knowledge
def self.for_current_user(session)
  where(user_id: session[:user_id])
end

# ❌ Email sending / side effects unrelated to persistence
after_create :send_notification_email

# ❌ Authorization decisions
def can_be_edited_by?(user)
  user.admin? || user == self.creator   # belongs in a Policy
end

# ❌ Formatting for display
def formatted_created_at
  created_at.strftime("%B %d, %Y")     # belongs in a Presenter
end
```

---

### GitLab on Omniscient (God) Models

GitLab's [Software Design guide](https://docs.gitlab.com/development/software_design/#taming-omniscient-classes) explicitly warns against god objects:

> "We must consider not adding new data and behavior to omniscient classes. We consider `Project`, `User`, `MergeRequest`, `Ci::Pipeline` and any classes above 1000 LOC to be omniscient."

Their rule of thumb: if adding a method to a model also pulls in several private helpers, those helpers belong in a dedicated class. The real GitLab codebase uses bounded-context namespaces (`AntiAbuse::UserTrustScore`, `Integrations::ProjectIntegrations`) to pull logic out of `User` and `Project`.

Applied to this project — if `Issue` started accumulating "close issue", "reopen issue", "assign label" methods, each would become a service object: `Issues::CloseService`, `Issues::ReopenService`, `Issues::AddLabelService`.

---

### The Controller — HTTP only

The controller is an **adapter between HTTP and your domain**. Its job is:

1. Parse and permit params
2. Call a model or service
3. Respond (redirect, render, JSON)

That's it. If you find yourself writing more than ~10 lines of logic in a controller action, extract it.

```ruby
# ✅ Correct controller — thin, HTTP-only
class IssuesController < ApplicationController
  before_action :set_project
  before_action :set_issue, only: [:show, :edit, :update, :destroy]

  def create
    @issue = @project.issues.new(issue_params)   # model handles validation
    respond_to do |format|
      if @issue.save                              # persistence in model
        format.html { redirect_to @issue, notice: "Issue created." }
        format.json { render json: @issue, status: :created }
      else
        format.html { render :new, status: :unprocessable_content }
        format.json { render json: @issue.errors, status: :unprocessable_content }
      end
    end
  end

  private

  def issue_params
    params.require(:issue).permit(:title, :description, :author_name, :status)
  end
end
```

**What does NOT belong in the controller:**

```ruby
# ❌ Business logic
def create
  issue = Issue.new(issue_params)
  if issue.save
    # send email, update counters, create audit log...  → service object
  end
end

# ❌ Database queries beyond simple finds
def index
  @open = Issue.where(status: :open).where("created_at > ?", 30.days.ago)
    .joins(:labels).where(labels: { name: "bug" })   # → scope or query object
end

# ❌ Authorization logic inline
def update
  if current_user.admin? || current_user == @issue.author
    # ...                                             # → policy object
  end
end
```

---

### Service Objects — one use-case, one class

When an action involves more than one model, has side effects (email, audit log, webhooks), or requires complex permission checks, it belongs in a service object.

GitLab's naming convention from the software design guide:

```ruby
# Good — ubiquitous language, not CRUD
Issues::CloseService              # not Issues::UpdateStatusService
Epic::AddExistingIssueService
Projects::CreateService           # OK if it matches product language

# Bad — CRUD jargon that adds confusion
EpicIssues::CreateService         # ambiguous: create the record or add to an epic?
```

**Structure of a GitLab-style service object:**

```ruby
# app/services/issues/close_service.rb
module Issues
  class CloseService
    def initialize(issue:, current_user:)
      @issue = issue
      @current_user = current_user
    end

    def execute
      return ServiceResponse.error(message: "Not authorized") unless authorized?

      @issue.update!(status: :closed, closed_at: Time.current)
      notify_subscribers
      create_audit_event

      ServiceResponse.success(payload: { issue: @issue })
    end

    private

    def authorized?
      @current_user.admin? || @issue.project.member?(@current_user)
    end

    def notify_subscribers
      IssueMailer.closed_notification(@issue).deliver_later
    end

    def create_audit_event
      AuditEvent.create!(author: @current_user, target: @issue, action: "closed")
    end
  end
end
```

**Called from the controller:**

```ruby
def destroy
  result = Issues::CloseService.new(issue: @issue, current_user: current_user).execute
  respond_to do |format|
    if result.success?
      format.html { redirect_to project_issues_path(@issue.project), notice: "Closed." }
      format.json { head :no_content }
    else
      format.json { render json: { error: result.message }, status: :forbidden }
    end
  end
end
```

**Why service objects instead of fat models or fat controllers:**

- A single permission check guards the whole use-case — no scattered `if user.admin?` across views and controllers
- Side effects are explicit and co-located
- Testable in isolation without HTTP overhead
- Different use-cases (close vs delete vs reopen) don't bleed into each other

---

### Workers (Sidekiq) — async execution

If a service object involves slow or non-critical work (email, webhooks, search indexing), move the slow parts to a Sidekiq worker:

```ruby
# app/workers/issues/close_notification_worker.rb
module Issues
  class CloseNotificationWorker
    include Sidekiq::Worker

    sidekiq_options queue: :default, retry: 3

    def perform(issue_id, user_id)
      issue = Issue.find(issue_id)
      user  = User.find(user_id)
      IssueMailer.closed_notification(issue, user).deliver_now
    end
  end
end
```

Called from the service:

```ruby
Issues::CloseNotificationWorker.perform_async(@issue.id, @current_user.id)
```

**Rules from GitLab's guide:**

- Workers must be backwards-compatible across deploys — the queue may contain jobs from the previous version of the code
- Never change a worker method signature without a two-release migration strategy (accept both old and new arguments in the first release)
- Workers should be idempotent — safe to retry on failure

---

### Presenters / Decorators — view formatting

Formatting logic (date formats, truncation, CSS classes derived from state) does not belong in models or views. It belongs in a presenter:

```ruby
# app/presenters/issue_presenter.rb
class IssuePresenter
  def initialize(issue)
    @issue = issue
  end

  def status_badge_class
    { "open" => "badge-success", "in_progress" => "badge-warning", "closed" => "badge-secondary" }
      .fetch(@issue.status, "badge-light")
  end

  def created_at_display
    @issue.created_at.strftime("%b %d, %Y")
  end

  def truncated_description(limit = 100)
    @issue.description&.truncate(limit)
  end
end

# In the view:
presenter = IssuePresenter.new(@issue)
presenter.status_badge_class   # => "badge-success"
presenter.created_at_display   # => "Mar 25, 2026"
```

---

### Query Objects / Finders — complex queries

Complex queries with multiple conditions, joins, or dynamic filters can overwhelm a model's scope chain. GitLab uses a `Finders` pattern:

```ruby
# app/finders/issues_finder.rb
class IssuesFinder
  def initialize(project:, params: {})
    @project = project
    @params  = params
  end

  def execute
    scope = @project.issues
    scope = scope.by_status(@params[:status])   if @params[:status].present?
    scope = scope.with_labels                   if @params[:with_labels]
    scope = scope.recent
    scope
  end
end

# In the controller:
@issues = IssuesFinder.new(project: @project, params: filter_params).execute
```

This keeps the `Issue` model clean and makes the finder independently testable.

---

### Validators — reusable validation logic

When a validation rule applies across multiple models, extract it into `app/validators/`:

```ruby
# app/validators/no_profanity_validator.rb  (already in this project)
class NoProfanityValidator < ActiveModel::EachValidator
  DEFAULT_BLACKLIST = %w[foo bar baz]

  def initialize(options)
    super
    @blacklist = Array(options[:words]) + DEFAULT_BLACKLIST
  end

  def validate_each(record, attribute, value)
    return if value.blank?
    found = @blacklist.find { |word| value.to_s.downcase.include?(word.downcase) }
    return unless found
    message = options[:message] || "contains disallowed word: #{found}"
    record.errors.add(attribute, message)
  end
end

# Usable in any model:
validates :title,   no_profanity: true
validates :content, no_profanity: { words: %w[spam] }
```

Contrast with **inline validation** (`validate :method_name`), which is model-specific and does not need to be reused:

```ruby
# In Issue model — specific to this model's domain rule
validate :author_name_cannot_contain_digits

private

def author_name_cannot_contain_digits
  return if author_name.blank?
  errors.add(:author_name, "cannot contain numbers") if author_name.match?(/\d/)
end
```

**Rule of thumb**: if the validation logic will be used in exactly one model, use an inline `validate` method. If it crosses models, use a validator class.

---

### GitLab's Bounded Contexts — namespaces as domain guardrails

GitLab's [software design guide](https://docs.gitlab.com/development/software_design/#bounded-contexts) introduces the concept of bounded contexts enforced through Ruby namespaces:

> "We should expect any class to be defined inside a module/namespace that represents the contexts where it operates."

What this means in practice:

```ruby
# ❌ Bad — no context, leaks into the global namespace
class JobArtifact; end

# ✅ Good — nested under the CI bounded context
module Ci
  class JobArtifact; end
end

# ❌ Bad — CRUD name, ambiguous context
class EpicIssues::CreateService; end

# ✅ Good — ubiquitous language inside a domain namespace
class Epic::AddExistingIssueService; end
```

For this project, the same principle applies:

```text
app/
  services/
    issues/
      close_service.rb          # Issues:: bounded context
      reopen_service.rb
    projects/
      archive_service.rb        # Projects:: bounded context
  workers/
    issues/
      close_notification_worker.rb
  finders/
    issues_finder.rb
  presenters/
    issue_presenter.rb
  validators/
    no_profanity_validator.rb
```

---

### The "design around use-cases" rule

GitLab's guide is explicit:

> "Rails encourages entity-centric software. This anti-pattern manifests as: different preconditions checked for different use-cases in the same service, different permissions checked in the same abstraction, different side-effects triggered by 'if field X changed, do Y'."

**Anti-pattern** — one bloated service handles two completely different actors:

```ruby
# ❌ Bad — Groups::UpdateService handles two different actors and permission sets
class Groups::UpdateService
  def execute
    if params[:shared_runners_minutes_limit]   # only instance admins
      # ...
    elsif params[:description]                 # any group admin
      # ...
    end
  end
end
```

**Solution** — separate services for separate use-cases:

```ruby
# ✅ Good — each service has one actor, one permission check, one cohesive set of params
class Groups::UpdateService; end               # group admin, description/avatar/settings
class Ci::Minutes::UpdateLimitService; end     # instance admin, quota only
```

Applied to this project:

```ruby
# ❌ Avoid
class Issues::UpdateService
  def execute
    if params[:status] == "closed"
      # close logic, notifications, audit log...
    elsif params[:label_ids]
      # label update logic, webhooks...
    end
  end
end

# ✅ Prefer
class Issues::CloseService; end
class Issues::AddLabelService; end
class Issues::RemoveLabelService; end
```

---

### Quick-reference decision table

| Situation | Where it goes |
| --- | --- |
| Validate data before saving | Model (`validates` / `validate :method`) — or `app/validators/` if reusable across models |
| Association, enum, scope | Model |
| Parse params, call model/service, redirect/render | Controller |
| Business logic touching > 1 model or with side effects | Service object (`app/services/`) |
| Authorization (can user X do Y?) | Policy object (`app/policies/`) |
| Slow work: email, webhooks, indexing | Sidekiq worker (`app/workers/`) |
| Date formatting, badge classes, display helpers | Presenter (`app/presenters/`) |
| Complex DB query with dynamic filters | Finder / query object (`app/finders/`) |
| JSON shape definition | Jbuilder template or serializer |
| Reusable multi-model validation | Validator class (`app/validators/`) |

---

### Where logic lives in this project

| Concern | File |
| --- | --- |
| Issue validations (presence, length, no profanity, no digit author) | `app/models/issue.rb` |
| Reusable profanity check | `app/validators/no_profanity_validator.rb` |
| HTTP request/response for issues | `app/controllers/issues_controller.rb` |
| HTTP request/response for projects | `app/controllers/projects_controller.rb` |
| JSON shape for project list | `app/views/projects/index.json.jbuilder` |
| JSON shape for project + its issues | `app/views/projects/show.json.jbuilder` |
| JSON shape for single issue + labels | `app/views/issues/show.json.jbuilder` |
| (future) Close / reopen workflow | `app/services/issues/close_service.rb` |
| (future) Async notifications | `app/workers/issues/close_notification_worker.rb` |

---

### Where Logic Lives — Interview Q&A

**Q: What is the "fat model, skinny controller" rule and why is it considered incomplete?**
"Fat model, skinny controller" moves business logic from controllers into models — better than bloated controllers. But taken too far it creates god models: a `User` or `Project` with thousands of lines spanning dozens of domains. The complete answer is: models own *domain invariants and persistence*, controllers own *HTTP*, and anything more complex goes into service objects, workers, presenters, or finders.

**Q: When do you extract a service object?**
When an action: (a) touches more than one model, (b) has side effects like email, webhooks, or audit logs, (c) needs a single authorization check guarding the whole operation, or (d) represents a named business use-case testable in isolation. A useful heuristic: if you are writing more than ~10 lines of business logic in a controller action, extract it.

**Q: How does GitLab name service objects?**
GitLab uses ubiquitous language — the name matches what users do, not what database operation occurs. `Epic::AddExistingIssueService` instead of `EpicIssues::CreateService`. `Issues::CloseService` instead of `Issues::UpdateStatusService`. This makes code searchable and avoids translation overhead for readers.

**Q: What is the difference between a validator class and an inline `validate` method?**
An inline `validate :method_name` lives inside one model and encodes a rule specific to that model's domain (e.g., "author name cannot contain digits" belongs to `Issue`). A validator class inheriting from `ActiveModel::EachValidator` lives in `app/validators/` and can be reused across any model with `validates :field, my_rule: true`. Use a class when the rule crosses models; use an inline method when it is specific to one.

**Q: What goes in a presenter?**
Formatting logic: display date strings, CSS class names derived from model state, text truncation, computed display-only attributes. Presenters keep models free of view concerns and views free of logic, and make formatting independently testable.

**Q: What are Sidekiq workers for and what is the key constraint on them?**
Background execution of slow or non-critical work: email delivery, external webhooks, search indexing, audit events. They are enqueued by service objects (not controllers). The key constraint is **backwards compatibility**: the Sidekiq queue is not drained during a deploy, so a worker running new code may process jobs enqueued by old code. Never change a `perform` signature without a two-release migration strategy.

**Q: What does GitLab mean by "bounded contexts"?**
A bounded context is a Ruby namespace that groups related domain classes. `Ci::`, `MergeRequests::`, `Issues::` are bounded contexts in GitLab's codebase. Code related to CI lives under `Ci::`, not scattered at the top level. This makes coupling visible — excessive cross-namespace imports signal a misplaced abstraction. GitLab enforces it with the `Gitlab/BoundedContexts` RuboCop cop.
