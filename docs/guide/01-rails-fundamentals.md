# Rails Interview Guide — Part 1: Rails Fundamentals

> Sections 1–12: Setup, Migrations, Models, Validations, Enums, CRUD, Zeitwerk, Routing, Controllers, Views, String Helpers, Initializers

[← Back to index](README.md)

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

### 2.1 What is a migration?

A **migration** is a Ruby class that describes a single, incremental change
to your database schema. Instead of writing raw SQL (`ALTER TABLE …`) and
sharing it out-of-band, each change lives in a versioned file that is:

- **tracked in Git** alongside the application code that depends on it
- **repeatable** — any developer or CI server can replay the exact same
  sequence from scratch
- **reversible** — Rails can run migrations forwards (`db:migrate`) or
  backwards (`db:rollback`), as long as you write them correctly

Every migration file lives in `db/migrate/` and is named with a timestamp
prefix plus a descriptive name:

```text
db/migrate/
  20260322102554_create_projects.rb
  20260322102626_create_issues.rb
  20260322102634_create_labels.rb
  20260322102851_add_not_null_constraints.rb
  20260322103020_create_issue_labels.rb
  20260323144818_add_author_name_to_issues.rb
  20260323144942_backfill_author_name_on_issues.rb
  20260323145039_add_not_null_to_issues_author_name.rb
```

The timestamp (e.g. `20260322102554`) is the migration **version**. Rails
uses it to decide which migrations have run and in what order.

---

### 2.2 How migrations work — the lifecycle

```text
Your code                   Rails internals              Database
────────────────────────────────────────────────────────────────────
rails db:migrate
  │
  ├─ reads db/migrate/*.rb sorted by timestamp
  │
  ├─ checks schema_migrations table ──────────────────> SELECT version
  │    (created automatically the first time)            FROM schema_migrations
  │
  ├─ runs each migration not yet in schema_migrations
  │    calls migration.change (or .up)
  │    wraps in a DDL transaction (unless disabled) ──> BEGIN
  │                                                      ALTER TABLE …
  │                                                      CREATE INDEX …
  │                                                      COMMIT
  │
  └─ records the version ─────────────────────────────> INSERT INTO schema_migrations
                                                          VALUES ('20260322102554')
```

**Key internal table — `schema_migrations`**:

```sql
SELECT * FROM schema_migrations ORDER BY version;
-- version
-- --------------------
-- 20260322102554
-- 20260322102626
-- 20260322102634
-- 20260322102851
-- 20260322103020
-- 20260323144818
-- 20260323144942
-- 20260323145039
```

A migration is "up" if its version is in this table; "down" if it is not.
`rails db:rollback` removes the last version from this table and runs `down`
(or reverses `change`).

---

### 2.3 When to create a migration

| Situation | What to do |
| --- | --- |
| Adding a new table | `rails g migration CreateWidgets name:string` |
| Adding a column to an existing table | `rails g migration AddColorToLabels color:string` |
| Removing a column | `rails g migration RemoveColorFromLabels color:string` |
| Adding an index | `rails g migration AddIndexToIssuesStatus` |
| Adding a foreign key | `rails g migration AddForeignKeyIssuesToProjects` |
| Renaming a table or column | `rails g migration RenameOldTableToNew` |
| Changing a column type | `rails g migration ChangeStatusOnIssues` |
| Backfilling data | Separate migration from the schema change (see 2.6) |

**Convention**: migration names follow the pattern `VerbNounToTable`
(`AddStatusToIssues`, `CreateLabels`, `RemoveArchivedFromProjects`). Rails
uses the name to infer DSL calls when you pass column specs:

```bash
# Rails auto-generates add_column :labels, :color, :string
rails g migration AddColorToLabels color:string

# Rails auto-generates remove_column :labels, :color, :string
rails g migration RemoveColorFromLabels color:string
```

---

### 2.4 Generating migrations

```bash
rails generate migration CreateProjects name:string description:text
rails generate migration CreateIssues title:string description:text status:integer project:references
rails generate migration CreateLabels name:string color:string
rails generate migration CreateIssueLabels issue:references label:references
```

A generated file always inherits from `ActiveRecord::Migration[X.Y]` — the
version number locks the migration to the Rails API that existed when it was
written, so it continues to work even if the API changes in future Rails
versions.

```ruby
class CreateProjects < ActiveRecord::Migration[8.1]
  def change
    create_table :projects do |t|
      t.string :name
      t.text   :description
      t.timestamps
    end
  end
end
```

---

### 2.5 What `references` does automatically

`project:references` is Rails shorthand that generates **three things** at once:

1. A `project_id bigint` column
2. A **database index** on `project_id` — critical for JOIN performance
3. A **foreign key constraint** — referential integrity enforced at the DB level

```ruby
# What Rails generates:
create_table :issues do |t|
  t.references :project, null: false, foreign_key: true
  # ↑ equivalent to:
  # t.bigint :project_id, null: false
  # add_index :issues, :project_id
  # add_foreign_key :issues, :projects
end
```

---

### 2.6 `null: false` — Defence in depth

Always enforce constraints at **both** the DB level and application level:

```ruby
# DB layer — migration
change_column_null :projects, :name, false

# App layer — model
validates :name, presence: true
```

If someone bypasses the app (rake task, rails console, direct SQL), the DB
constraint is your last line of defence.

---

### 2.7 Migration commands cheat sheet

```bash
rails db:migrate                    # run all pending migrations
rails db:migrate VERSION=20260322   # migrate up to a specific version
rails db:rollback                   # undo the last migration
rails db:rollback STEP=3            # undo the last 3 migrations
rails db:migrate:status             # show up/down status for every migration
rails db:migrate:redo               # rollback then re-migrate the last migration
rails db:schema:load                # load db/schema.rb directly (faster than replaying all migrations)
rails db:reset                      # drop + create + schema:load + seed
rails db:drop db:create db:migrate  # full cycle (preserves migration history)
```

---

### 2.8 `schema.rb` — The source of truth

After every `rails db:migrate`, Rails re-generates `db/schema.rb` by
inspecting the **live database state**. It is not a concatenation of
migration files — it is a snapshot of what the database actually looks like
right now.

Here is the actual `schema.rb` for this project:

```ruby
# db/schema.rb (auto-generated — do not edit by hand)
ActiveRecord::Schema[8.1].define(version: 2026_03_23_145039) do
  enable_extension "pg_catalog.plpgsql"

  create_table "issue_labels", force: :cascade do |t|
    t.bigint   "issue_id",   null: false
    t.bigint   "label_id",   null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["issue_id"], name: "index_issue_labels_on_issue_id"
    t.index ["label_id"], name: "index_issue_labels_on_label_id"
  end

  create_table "issues", force: :cascade do |t|
    t.string   "title",       null: false
    t.text     "description"
    t.integer  "status",      null: false
    t.bigint   "project_id",  null: false
    t.string   "author_name", null: false
    t.datetime "created_at",  null: false
    t.datetime "updated_at",  null: false
    t.index ["project_id"], name: "index_issues_on_project_id"
  end

  create_table "labels", force: :cascade do |t|
    t.string   "name",       null: false
    t.string   "color",      null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "projects", force: :cascade do |t|
    t.string   "name",        null: false
    t.text     "description"
    t.datetime "created_at",  null: false
    t.datetime "updated_at",  null: false
  end

  add_foreign_key "issue_labels", "issues"
  add_foreign_key "issue_labels", "labels"
  add_foreign_key "issues", "projects"
end
```

**What it contains**:

- `version:` — the timestamp of the last migration that ran
- `enable_extension` — any PostgreSQL extensions that must exist
- One `create_table` block per table, with columns and indexes
- `add_foreign_key` calls at the end (always after all tables are created)

**What it does NOT contain**:

- The history of how you got here (that's what migration files are for)
- Anything that was added and then removed (schema.rb shows only the final state)

#### Why `schema.rb` exists

| Problem with replaying migrations | How `schema.rb` solves it |
| --- | --- |
| Old migrations reference app models (`Issue.find_each`) that may no longer exist or have changed | `schema.rb` contains only structural DSL — no app code |
| 200 migrations take minutes to replay | `db:schema:load` runs in seconds |
| Migrations may contain bugs from years ago | `schema.rb` is always valid — it was written from the live DB |

#### `schema.rb` vs `structure.sql`

Rails supports two schema formats:

| | `schema.rb` (default) | `structure.sql` |
| --- | --- | --- |
| **Format** | Ruby DSL | Raw SQL dump (`pg_dump`) |
| **Portability** | Works with any AR-supported DB | Database-specific |
| **Captures** | Tables, columns, indexes, FKs | Everything above + views, triggers, stored procedures, custom types |
| **When to use** | Most apps | When you use PG-specific features schema.rb can't represent |

Set in `config/application.rb`:

```ruby
config.active_record.schema_format = :sql  # generates db/structure.sql
```

**Rule**: use `schema.rb` unless you have views, triggers, or custom PG
types that it cannot represent.

#### Always commit `schema.rb`

- It is the canonical description of your DB for new developers
- CI and Heroku-style deploys use `db:schema:load` not `db:migrate` for
  fresh environments
- PRs that add migrations without updating `schema.rb` are invalid —
  `rails db:migrate` updates it automatically, so just remember to `git add db/schema.rb`

---

### 2.9 Real example — the author_name migration trilogy

Adding a non-nullable column to an existing table that may have live data
requires three separate migrations (the zero-downtime pattern, covered in
detail in Section 16):

```ruby
# Step 1 — add nullable, no default (instant, no table lock)
class AddAuthorNameToIssues < ActiveRecord::Migration[8.1]
  def change
    add_column :issues, :author_name, :string
  end
end

# Step 2 — backfill existing rows in batches (never lock the whole table)
class BackfillAuthorNameOnIssues < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!  # lets each batch commit independently

  def up
    issue_relation = define_model("issues", :author_name, :id)
    issue_relation.where(author_name: nil).in_batches(of: 1000) do |batch|
      batch.update_all(author_name: "unknown")
      sleep(0.01)
    end
  end

  def down; end  # backfills are not reversed
end

# Step 3 — add NOT NULL constraint now that no NULLs remain
class AddNotNullToIssuesAuthorName < ActiveRecord::Migration[8.1]
  def up
    change_column_null :issues, :author_name, false
  end

  def down
    change_column_null :issues, :author_name, true
  end
end
```

After all three migrations run, `schema.rb` shows only the final result:

```ruby
t.string "author_name", null: false
```

The three-step history is preserved in the migration files; `schema.rb`
captures only the destination.

---

### 2.10 Common interview questions

**Q: What is a Rails migration and why do we use them instead of raw SQL?**

> A migration is a versioned Ruby class that describes an incremental
> database change. They are tracked in `schema_migrations`, can be run
> forward and rolled back, and live alongside the code that depends on them
> in Git. Raw SQL is not automatically tracked, ordered, or reversible.

**Q: What is `schema.rb` and how does it differ from migration files?**

> `schema.rb` is a Rails-generated snapshot of the current database
> structure written as Ruby DSL. Migration files describe the *history* of
> changes; `schema.rb` describes the *current state*. New environments use
> `db:schema:load` (fast) rather than replaying all migrations (slow and
> potentially fragile).

**Q: When would you use `structure.sql` instead of `schema.rb`?**

> When the application uses database features that `schema.rb`'s Ruby DSL
> cannot express: views, triggers, stored procedures, custom PostgreSQL
> types (e.g. enums defined at the DB level), or check constraints on
> older Rails versions. `structure.sql` is a raw `pg_dump` output and
> is database-specific.

**Q: What does `db:reset` do vs `db:migrate`?**

> `db:reset` drops the database, creates it, loads `schema.rb`, and runs
> seeds — it gives you a clean slate. `db:migrate` only runs pending
> migrations against an existing database. Never run `db:reset` in
> production.

**Q: Why should you never edit `schema.rb` by hand?**

> `schema.rb` is auto-generated by Rails from the live database after
> every migration. Editing it manually is overwritten the next time any
> migration runs. Schema changes must always go through a migration.

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
