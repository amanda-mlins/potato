# Rails Interview Guide — Part 2: Database & SQL

> Sections 13–20: Scopes, N+1 Queries, SQL Joins, Zero-Downtime Migrations, DDL Transactions, PostgreSQL, Foreign Keys & Locks, Migration Methods

[← Back to index](README.md)

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


---

## 21. ActiveRecord Column Types × Database Data Types

Rails abstracts over the database with its own type system. When you write
`t.string` or `t.timestamps` in a migration, ActiveRecord translates that
into the best native type for the database you are connected to.
Understanding the mapping lets you choose the right type up-front (avoiding
costly migrations later) and answer confidently when interviewers probe the
difference between, say, `datetime` and `timestamp`.

---

### 21.1 The full type map

| AR type | PostgreSQL | SQLite | MySQL / MariaDB | Ruby class |
|---|---|---|---|---|
| `:primary_key` | `bigserial PRIMARY KEY` | `INTEGER PRIMARY KEY` | `BIGINT AUTO_INCREMENT PK` | `Integer` |
| `:string` | `character varying(255)` | `varchar(255)` | `varchar(255)` | `String` |
| `:text` | `text` | `text` | `mediumtext` | `String` |
| `:integer` | `integer` (4 B) | `integer` | `int(11)` | `Integer` |
| `:bigint` | `bigint` (8 B) | `integer` | `bigint(20)` | `Integer` |
| `:float` | `float` | `float` | `float` | `Float` |
| `:decimal` | `decimal(p,s)` | `decimal(p,s)` | `decimal(p,s)` | `BigDecimal` |
| `:numeric` | `numeric(p,s)` | `decimal(p,s)` | `decimal(p,s)` | `BigDecimal` |
| `:boolean` | `boolean` | `boolean` (0/1) | `tinyint(1)` | `true` / `false` |
| `:date` | `date` | `date` | `date` | `Date` |
| `:time` | `time without time zone` | `time` | `time` | `Time` |
| `:datetime` | `timestamp without time zone` | `datetime` | `datetime` | `ActiveSupport::TimeWithZone` |
| `:timestamp` | `timestamp without time zone` | `datetime` | `datetime` | `ActiveSupport::TimeWithZone` |
| `:binary` | `bytea` | `blob` | `blob` | `String` (binary) |
| `:json` | `json` | `text` (serialised) | `json` | `Hash` / `Array` |
| `:jsonb` | `jsonb` (indexed binary) | *(not supported)* | *(not supported)* | `Hash` / `Array` |
| `:uuid` | `uuid` | `varchar(36)` | `varchar(36)` | `String` |
| `:inet` | `inet` | *(not supported)* | *(not supported)* | `IPAddr` |
| `:hstore` | `hstore` | *(not supported)* | *(not supported)* | `Hash` |

> **Rule of thumb**: AR types are database-agnostic names. Native types (`jsonb`,
> `uuid`, `inet`) are PostgreSQL-specific and must be passed as strings
> (`t.column :ip, :inet`) or via `enable_extension`.

---

### 21.2 `datetime` vs `timestamp` — the most common interview question

In Rails migrations these two type names produce **identical DDL on every
database**. They are aliases for the same AR type object.

```ruby
# Both produce the exact same column:
t.datetime  :published_at   # → timestamp without time zone (PG)
t.timestamp :published_at   # → timestamp without time zone (PG)
```

The distinction lives at the **PostgreSQL level**, not the Rails level:

| PG type | Stores TZ? | Range | Rails keyword |
|---|---|---|---|
| `timestamp without time zone` | ❌ | 4713 BC – 294276 AD | `:datetime` / `:timestamp` |
| `timestamp with time zone` (`timestamptz`) | ✅ (converts to UTC) | same | `:timestamptz` (string literal) |

**What Rails actually does**: Rails normalises all times to UTC before
writing to the database (`config.time_zone` + `ActiveRecord::Base.default_timezone = :utc`).
Because Rails handles the time zone in application code, the column on disk
is almost always `timestamp without time zone`. The offset is never stored
in the column; it's stored nowhere — Rails knows it's UTC.

If you need PostgreSQL to enforce UTC storage at the database level (e.g.
multiple clients write directly), use `timestamptz` explicitly:

```ruby
# PostgreSQL-specific — not portable
add_column :issues, :resolved_at, :timestamptz
```

**SQLite note**: SQLite has no native date/time type. Rails stores
`datetime`/`timestamp` as ISO 8601 strings (`"2025-03-29 14:00:00.000000"`).
This usually works fine but watch out for string comparisons in raw SQL.

**MySQL note**: MySQL's `DATETIME` stores local time with no timezone awareness.
`TIMESTAMP` stores UTC and converts on read using the server's timezone.
This is the **opposite** of Rails' recommendation — always keep `default_timezone = :utc`
so Rails writes UTC to a `DATETIME` column (no conversion surprises).

---

### 21.3 `t.timestamps` — what does it actually add?

```ruby
# In a migration:
t.timestamps
```

Expands to exactly:

```ruby
t.datetime :created_at, null: false
t.datetime :updated_at, null: false
```

Rails sets both automatically:
- `created_at` — set once on `INSERT`, never touched again
- `updated_at` — set on every `INSERT` and `UPDATE` (including `touch`)

Both become `timestamp without time zone NOT NULL` in PostgreSQL.

In our project's `CreateProjects` migration:

```ruby
create_table :projects do |t|
  t.string :name        # → varchar(255)
  t.text   :description # → text (unlimited length)
  t.timestamps          # → created_at + updated_at (timestamp NOT NULL)
end
```

---

### 21.4 `string` vs `text`

| | `:string` | `:text` |
|---|---|---|
| **PostgreSQL** | `varchar(255)` (default limit) | `text` (unlimited) |
| **SQLite** | `varchar(255)` | `text` |
| **MySQL** | `varchar(255)` | `mediumtext` (≤ 16 MB) |
| **Indexed?** | Fully indexable | PG: indexable; MySQL: prefix index only |
| **Validation** | AR enforces `length` if you add it | AR enforces `length` if you add it |
| **When to use** | Short, bounded values — names, slugs, titles | Long, unbounded prose — descriptions, bodies |

You can override the limit on `:string`:

```ruby
t.string :title,  limit: 500   # → varchar(500) on PG / MySQL
t.string :status, limit: 20    # fine for an enum-like column
```

In our `CreateIssues` migration:

```ruby
t.string :title          # varchar(255) — good: titles are short
t.text   :description    # text — good: descriptions can be long
t.integer :status        # stores the enum ordinal (0, 1, 2 …)
```

---

### 21.5 `integer` vs `bigint`

| | `:integer` | `:bigint` |
|---|---|---|
| **Size** | 4 bytes | 8 bytes |
| **Range** | −2,147,483,648 → 2,147,483,647 | −9.2 × 10¹⁸ → 9.2 × 10¹⁸ |
| **PG type** | `integer` | `bigint` |
| **Default PK** | `:primary_key` → `bigserial` (bigint) since Rails 5.1 | same |

Since Rails 5.1, `create_table` generates `bigserial` primary keys by default.
Foreign keys created with `t.references` are also `bigint` to match.

```ruby
# In CreateIssues — Rails generates a bigint id:
create_table :issues do |t|
  # implicit: id bigserial PRIMARY KEY
  t.references :project, null: false, foreign_key: true
  # → project_id bigint NOT NULL REFERENCES projects(id)
end
```

Use `:integer` only for columns that will never exceed ~2 billion values
(e.g. enum ordinals, small counters). Prefer `:bigint` for anything that
grows.

---

### 21.6 `float` vs `decimal` / `numeric`

| | `:float` | `:decimal` / `:numeric` |
|---|---|---|
| **PG type** | `double precision` (IEEE 754, 8 B) | `decimal(p, s)` (exact) |
| **Precision** | ~15–17 significant digits, **inexact** | Exact to `p` digits, `s` after decimal |
| **Ruby class** | `Float` | `BigDecimal` |
| **Use for** | Scientific values, ML scores, approximations | Money, rates, measurements requiring exactness |

```ruby
# Wrong — floating-point errors accumulate:
t.float :price

# Correct — exact arithmetic:
t.decimal :price, precision: 10, scale: 2  # → decimal(10,2) on PG
```

Rule: **never use `:float` for money**. Use `:decimal` with `precision` and
`scale`, or store the value in cents as an `:integer`.

---

### 21.7 `:boolean`

| Database | Column type | True stored as | False stored as |
|---|---|---|---|
| PostgreSQL | `boolean` | `true` | `false` |
| SQLite | `boolean` (affinity) | `1` | `0` |
| MySQL | `tinyint(1)` | `1` | `0` |

ActiveRecord normalises all three to Ruby `true` / `false`.

**Gotcha — PostgreSQL**:

```sql
-- This is VALID in PG:
SELECT * FROM issues WHERE archived = true;
-- This is NOT VALID:
SELECT * FROM issues WHERE archived = 1;  -- PG rejects it
```

**Gotcha — SQLite in tests**: because SQLite stores booleans as integers,
queries like `WHERE archived = 'true'` will silently return no rows. Always
compare against the boolean, not a string.

---

### 21.8 `:json` vs `:jsonb` (PostgreSQL)

| | `:json` | `:jsonb` |
|---|---|---|
| **Storage** | Text (exact copy) | Binary (parsed, re-serialised) |
| **Indexable** | ❌ (only full-column) | ✅ GIN index on keys/values |
| **Operators** | `->`, `->>` | `->`, `->>`, `@>`, `?`, `?|`, `?&` |
| **Size** | Slightly smaller | Slightly larger |
| **Speed** | Slower queries | Faster queries |
| **Preserve key order** | ✅ | ❌ |

```ruby
# SQLite / MySQL: falls back to serialised text — no query operators
add_column :issues, :metadata, :jsonb, default: {}

# Query in Rails:
Issue.where("metadata @> ?", { source: "api" }.to_json)
```

Use `:json` only when you need to preserve insertion order or exact
whitespace. In all other cases, use `:jsonb`.

---

### 21.9 `:uuid` as primary key

PostgreSQL ships with the `pgcrypto` extension which generates UUID v4:

```ruby
# Migration:
enable_extension "pgcrypto"

create_table :api_tokens, id: :uuid do |t|
  t.references :project, type: :uuid, foreign_key: true, null: false
  t.string :name, null: false
  t.timestamps
end
```

```ruby
# config/initializers/generators.rb
Rails.application.config.generators do |g|
  g.orm :active_record, primary_key_type: :uuid
end
```

Tradeoffs:

| | Auto-increment bigint | UUID |
|---|---|---|
| **Predictability** | Sequential — easy to guess | Random — hard to enumerate |
| **Index locality** | B-tree stays sorted → fast inserts | Random → index bloat, page splits |
| **Distributed ID** | Needs coordination | Self-generating per node |
| **Readability in URLs** | `/issues/42` | `/issues/550e8400-…` |

In our project we use default `bigserial` PKs — fine for a single-node app.
UUID makes more sense for distributed systems or when you don't want to
expose record counts via URL.

---

### 21.10 How to inspect what Rails really generates

```bash
# See the actual SQL Rails will run:
bundle exec rails db:migrate:status

# Check the column types Rails sees after migration:
bundle exec rails db      # opens psql (PG) or sqlite3
```

In psql:
```sql
-- Describe the issues table:
\d issues

-- Output (abbreviated):
--  Column      | Type                        | Nullable
-- -------------+-----------------------------+---------
--  id          | bigint                      | not null
--  title       | character varying(255)      | not null
--  description | text                        |
--  status      | integer                     | not null
--  project_id  | bigint                      | not null
--  created_at  | timestamp without time zone | not null
--  updated_at  | timestamp without time zone | not null
```

From Rails console:
```ruby
# Inspect column metadata at runtime:
Issue.columns.map { |c| [c.name, c.type, c.sql_type] }
# => [["id", :integer, "bigint"],
#     ["title", :string, "character varying(255)"],
#     ["description", :text, "text"],
#     ["status", :integer, "integer"],
#     ["project_id", :integer, "bigint"],
#     ["created_at", :datetime, "timestamp without time zone"],
#     ["updated_at", :datetime, "timestamp without time zone"]]

# Check one column:
Issue.column_for_attribute(:created_at).sql_type
# => "timestamp without time zone"
```

---

### 21.11 Common interview questions

**Q: What is the difference between `datetime` and `timestamp` in Rails?**

> In Rails migrations they are **identical** — both produce
> `timestamp without time zone` in PostgreSQL. The distinction is at the
> PostgreSQL level: `timestamp` vs `timestamptz` (with timezone). Rails always
> stores UTC and normalises timezone in application code, so you rarely need
> `timestamptz` unless non-Rails clients write directly to the DB.

**Q: Why does `t.timestamps` use `datetime` and not `timestamp`?**

> Historically, `timestamp` in MySQL had a range limit (1970–2038) and
> auto-update behaviour that Rails didn't want. Using `:datetime` (which maps
> to MySQL `DATETIME`, PostgreSQL `timestamp without time zone`) gives uniform
> semantics across databases. Rails manages UTC conversion itself.

**Q: Should I use `:float` or `:decimal` for a price column?**

> Always `:decimal` with explicit `precision` and `scale`. `float` (IEEE 754)
> cannot represent most decimal fractions exactly — `0.1 + 0.2 != 0.3` in
> floating-point arithmetic. Money arithmetic requires exactness;
> `BigDecimal` (backed by `decimal(p,s)`) provides it.

**Q: What does `t.references :project` generate?**

> It adds a `project_id bigint NOT NULL` column plus (optionally) an index
> and a foreign key constraint. With `null: false, foreign_key: true` it also
> adds `REFERENCES projects(id)` at the DB level. The column is `bigint`
> because primary keys default to `bigserial` since Rails 5.1.

**Q: How do I store free-form metadata in a PostgreSQL-backed Rails app?**

> Use `:jsonb` — it is stored as parsed binary (faster queries), supports
> GIN indexes for key/value lookup, and provides rich operators (`@>`, `?`).
> Use `:json` only if you need to preserve insertion order.

**Q: Why might a boolean query work in development (SQLite) but fail in production (PostgreSQL)?**

> SQLite stores booleans as integers (`0`/`1`) and accepts string
> comparisons. PostgreSQL enforces strict boolean semantics — querying
> `WHERE active = 1` or `WHERE active = 'true'` raises a type error. Always
> use `true`/`false` literals or AR's query interface to stay portable.

---

#### Next up: Testing with RSpec / Minitest (Section 22)

---
