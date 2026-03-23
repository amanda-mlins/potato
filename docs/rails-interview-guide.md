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

*Next up: Views, Partials, and Form Helpers*
