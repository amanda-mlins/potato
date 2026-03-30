# Rails Interview Guide — Part 3: Testing

> Sections 21, 27–28: RSpec & The GitLab Way, Capybara & System Tests, The Testing Pyramid

[← Back to index](README.md)

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


---

## 27. Capybara & System Tests — Drivers, DSL, and Best Practices

System tests are end-to-end tests that drive a real browser (or a headless one) through your application. They catch bugs that unit and integration tests miss: JavaScript interactions, full request-response cycles, cookie/session handling, real SQL queries, real middleware. **Capybara** is the Ruby library that makes this possible. This section covers what Capybara is, how drivers work, the full DSL, configuration in Rails, and how to write reliable system tests.

---

### What Capybara is — and what it is not

Capybara is a **browser automation DSL** for Ruby. It provides a high-level API (`visit`, `click_on`, `fill_in`, `expect(page).to have_content`) and sits on top of a swappable **driver** that does the actual browser control. Capybara itself has no idea what browser is being used — that's the driver's job.

```text
Test code (RSpec / Minitest)
        ↓
    Capybara DSL
        ↓
    Driver layer          ← rack_test, Selenium, Cuprite, Playwright
        ↓
  Browser / HTTP stack    ← real Chromium, Firefox, or in-process Rack app
```

This separation means you can run the same test suite with the fast in-process driver during development and the full real-browser driver in CI.

---

### The driver landscape

| Driver | Library | Browser | JS support | Speed | Use case |
| --- | --- | --- | --- | --- | --- |
| `rack_test` | Built into Capybara | None — pure HTTP | ❌ No | ⚡ Fastest | Non-JS controller/integration tests |
| `selenium_chrome` | `selenium-webdriver` gem | Chrome / Chromium | ✅ Yes | 🐢 Slowest | Full real browser; most compatible |
| `selenium_chrome_headless` | `selenium-webdriver` gem | Headless Chrome | ✅ Yes | 🐢 Slow | CI without a display |
| `cuprite` | `cuprite` gem | Headless Chrome (CDP) | ✅ Yes | 🚀 Fast | Preferred modern headless driver |
| `playwright` | `playwright-ruby-client` | Chrome/Firefox/WebKit | ✅ Yes | 🚀 Fast | Multi-browser; newer alternative |

**`rack_test`** is the Rails default for request specs. It speaks HTTP directly to the Rack app — no browser, no JS, no CSS rendering. Fast, but it cannot test JavaScript-driven behaviour.

**Selenium** drives a real browser via the WebDriver protocol. Reliable, widely supported, but slow to start and flaky on timing if not tuned.

**Cuprite** drives Chrome via the Chrome DevTools Protocol (CDP) directly — no ChromeDriver intermediary. This makes it significantly faster than Selenium while still running real JavaScript.

---

### Rails system tests — setup

Rails 8 ships with system tests built on Capybara + Selenium out of the box.

**`test/application_system_test_case.rb`** (Minitest):

```ruby
require "test_helper"

class ApplicationSystemTestCase < ActionDispatch::SystemTestCase
  driven_by :selenium, using: :headless_chrome, screen_size: [1400, 1400]
end
```

**RSpec equivalent** — `spec/support/capybara.rb`:

```ruby
require "capybara/rspec"

RSpec.configure do |config|
  config.before(:each, type: :system) do
    driven_by :selenium, using: :headless_chrome, screen_size: [1400, 900]
  end
end
```

**Switching to Cuprite** (faster, recommended):

```ruby
# Gemfile
gem "cuprite", group: :test

# spec/support/capybara.rb
require "capybara/cuprite"

Capybara.register_driver(:cuprite) do |app|
  Capybara::Cuprite::Driver.new(app, window_size: [1400, 900], headless: true)
end

RSpec.configure do |config|
  config.before(:each, type: :system) do
    driven_by :cuprite
  end
end
```

---

### The Capybara DSL

#### Navigation

```ruby
visit root_path                              # GET a URL
visit project_issues_path(@project)
```

#### Finders — locating elements

```ruby
find("h1")                                   # CSS selector
find("#issue-title")                         # ID
find(".badge", text: "open")                 # selector + text filter
find(:xpath, "//table//tr[2]")              # XPath (avoid if possible)
find(:label, "Title")                        # accessible label
all(".issue-row")                            # returns all matching elements
first(".issue-row")                          # first match
```

#### Actions — interacting with the page

```ruby
click_on "New Issue"                         # matches <a> or <button> by text
click_button "Submit"                        # buttons only
click_link "Back"                            # links only

fill_in "Title", with: "Bug in login form"   # input/textarea by label text
fill_in "issue[title]", with: "Bug"         # by name attribute
select "In Progress", from: "Status"         # <select> by label
check "Send notifications"                   # checkbox
uncheck "Send notifications"
choose "Open"                                # radio button
attach_file "Attachment", "/path/to/file"    # file input

within("#issue-form") { click_on "Save" }    # scope actions to a container
```

#### Assertions — what to expect

```ruby
expect(page).to have_content("Issue created")
expect(page).to have_text("Bug in login form")
expect(page).to have_selector("h1", text: "Projects")
expect(page).to have_link("Edit", href: edit_issue_path(@issue))
expect(page).to have_button("Submit")
expect(page).to have_field("Title", with: "Bug")
expect(page).to have_select("Status", selected: "Open")
expect(page).to have_current_path(project_path(@project))

expect(page).not_to have_content("Deleted issue")
expect(page).to have_no_selector(".error-message")
```

#### Waiting — Capybara's killer feature

Capybara **automatically waits** for elements to appear. By default it retries assertions for up to 2 seconds. This handles AJAX responses, animations, and JS-rendered content without explicit `sleep` calls.

```ruby
# Capybara waits up to `Capybara.default_max_wait_time` (default: 2s)
expect(page).to have_content("Saved!")       # retries until found or timeout

# Override per-assertion
expect(page).to have_content("Report ready", wait: 10)

# Configure globally
Capybara.default_max_wait_time = 5
```

**Never use `sleep` in system tests.** It makes tests slow and fragile. If you feel the urge to add `sleep 1`, use `have_content` or `have_selector` with an appropriate `wait:` instead.

---

### Writing a system test for this project

```ruby
# spec/system/issues_spec.rb
require "rails_helper"

RSpec.describe "Issues", type: :system do
  let(:project) { create(:project, name: "Potato API") }

  before { driven_by :selenium, using: :headless_chrome }

  describe "creating an issue" do
    it "shows the new issue on the project page after creation" do
      visit new_project_issue_path(project)

      fill_in "Title",       with: "Login button broken"
      fill_in "Author name", with: "Alice"
      fill_in "Description", with: "Clicking login does nothing on Safari"
      select  "Open",        from: "Status"

      click_on "Create Issue"

      expect(page).to have_content("Issue was successfully created")
      expect(page).to have_content("Login button broken")
    end

    it "shows validation errors when title is blank" do
      visit new_project_issue_path(project)

      fill_in "Author name", with: "Alice"
      click_on "Create Issue"

      expect(page).to have_content("Title can't be blank")
      expect(page).to have_current_path(project_issues_path(project))
    end
  end

  describe "listing issues" do
    before do
      create(:issue, project: project, title: "First bug",   status: :open)
      create(:issue, project: project, title: "Second bug",  status: :closed)
    end

    it "lists all issues for the project" do
      visit project_issues_path(project)

      expect(page).to have_content("First bug")
      expect(page).to have_content("Second bug")
    end

    it "shows the status badge for each issue" do
      visit project_issues_path(project)

      within(".issue-row", text: "First bug")  { expect(page).to have_content("open")   }
      within(".issue-row", text: "Second bug") { expect(page).to have_content("closed") }
    end
  end
end
```

---

### Database cleaner strategy for system tests

System tests run in a separate thread (or process) from the test database connection. The default `transaction` rollback strategy that RSpec uses for unit tests **does not work** across threads — the browser-driven request uses a different connection and cannot see the rolled-back transaction.

**Fix — use `truncation` for system tests:**

```ruby
# spec/support/database_cleaner.rb
RSpec.configure do |config|
  config.before(:suite)    { DatabaseCleaner.clean_with(:truncation) }

  config.before(:each) do |example|
    strategy = example.metadata[:type] == :system ? :truncation : :transaction
    DatabaseCleaner.strategy = strategy
    DatabaseCleaner.start
  end

  config.after(:each) { DatabaseCleaner.clean }
end
```

Or with `database_cleaner-active_record`:

```ruby
config.before(:each, type: :system) { DatabaseCleaner.strategy = :truncation }
config.before(:each)                { DatabaseCleaner.strategy = :transaction }
```

---

### Debugging failing system tests

```ruby
# Take a screenshot at any point
save_screenshot("debug.png")
save_and_open_screenshot       # opens in your browser

# Dump the current page HTML
save_and_open_page

# Pause execution — useful with non-headless drivers
binding.pry   # or byebug

# Run a specific example non-headlessly to watch it
before { driven_by :selenium, using: :chrome }
```

**On CI** — configure Capybara to save screenshots of failures automatically:

```ruby
# spec/support/capybara.rb
RSpec.configure do |config|
  config.after(:each, type: :system) do |example|
    if example.exception
      save_screenshot("tmp/screenshots/#{example.description.parameterize}.png")
    end
  end
end
```

---

### Capybara configuration reference

```ruby
# spec/support/capybara.rb
Capybara.configure do |config|
  config.default_max_wait_time  = 5          # seconds to wait for async content
  config.default_driver         = :rack_test # for non-JS tests (fast)
  config.javascript_driver      = :cuprite   # for JS tests (tag with js: true)
  config.app_host               = "http://localhost"
  config.server_port            = 3001       # avoid clashing with dev server
  config.save_path              = "tmp/capybara"
  config.ignore_hidden_elements = :visible   # only interact with visible elements
end
```

Tag a test as JavaScript-only when you need the JS driver:

```ruby
it "submits the form via AJAX", js: true do
  visit new_project_issue_path(project)
  # ... Capybara will use javascript_driver for this example only
end
```

---

### Capybara vs request specs — when to use each

| | Request spec | System test |
| --- | --- | --- |
| Driver | `rack_test` (no browser) | Selenium / Cuprite (real browser) |
| JavaScript | ❌ Not tested | ✅ Fully tested |
| Speed | ⚡ Very fast | 🐢 Slower |
| Tests | Controllers, JSON, redirects, status codes | Full user flows, forms, JS interactions |
| Database cleaner | Transaction (fast) | Truncation (slower but correct) |
| Best for | API behaviour, rendering, auth | Critical user journeys, form submissions |

Use **request specs** for most controller behaviour. Use **system tests** for the handful of user journeys that matter most — the happy path for creating, editing, and deleting records; any flow that involves JavaScript.

---

### Capybara & System Tests — Interview Q&A

**Q: What is Capybara and what problem does it solve?**
Capybara is a Ruby DSL for browser automation. It sits on top of swappable drivers (Selenium, Cuprite, rack_test) and provides a human-readable API for navigating, interacting with, and asserting on web pages. It solves the problem of writing browser tests that read like user stories (`fill_in "Title", with: "…"`, `click_on "Submit"`, `expect(page).to have_content(…)`) without being coupled to a specific browser or protocol.

**Q: What is the difference between a driver and Capybara itself?**
Capybara is the DSL — it knows nothing about browsers. A driver is the adapter that translates Capybara commands into browser actions. `rack_test` simulates HTTP in-process with no browser. Selenium drives Chrome or Firefox via WebDriver. Cuprite drives Chrome via the Chrome DevTools Protocol directly. You can switch drivers without changing test code.

**Q: Why can't you use `rack_test` for JavaScript tests?**
`rack_test` makes HTTP requests directly to the Rack application in the same process — there is no browser, no rendering engine, and no JavaScript runtime. It cannot execute JS, respond to AJAX, or test anything that requires a real browser. For JavaScript behaviour you need Selenium or Cuprite.

**Q: Why does Capybara automatically wait, and when does it time out?**
Capybara retries DOM queries and assertions for up to `Capybara.default_max_wait_time` seconds (default: 2s). This handles asynchronous content: AJAX responses, turbo frames, animations, and JavaScript-rendered elements. If the condition isn't met within the timeout, the assertion fails. You can override per-assertion with `wait: N` or globally with `Capybara.default_max_wait_time = N`.

**Q: Why does the `transaction` database cleaner strategy break system tests?**
System tests drive a real browser, which sends HTTP requests that are handled by Rails in a separate thread (or process). That thread uses a different database connection than the test thread. A transaction opened in the test thread is invisible to other connections — so records created inside a `DatabaseCleaner.strategy = :transaction` block won't be visible to the browser-driven requests. The `truncation` strategy clears the database at the end of the test without relying on a shared transaction, so both connections see the same data.

**Q: What is Cuprite and why is it preferred over Selenium for headless testing?**
Cuprite drives Chrome directly via the Chrome DevTools Protocol, eliminating the ChromeDriver intermediary required by Selenium. This makes it significantly faster to start and more reliable under load. It supports the full Capybara DSL, has no external dependencies beyond Chrome itself, and is the recommended driver for headless system tests in modern Rails applications.

**Q: How do you debug a failing system test?**
`save_screenshot` / `save_and_open_screenshot` captures the page at the point of failure. `save_and_open_page` dumps the HTML. Running the test with a non-headless driver (`:selenium, using: :chrome`) lets you watch the browser interact with the page. On CI, configure an `after(:each)` hook that saves a screenshot whenever `example.exception` is non-nil, so failures are always captured even in headless mode.

---

## 28. The Testing Pyramid — Types of Tests in Rails & How GitLab Does It

The testing pyramid is a framework for deciding *how many* of each type of test to write and *when* to reach for each one. Understanding it is one of the most common senior-level interview topics — both because it affects team velocity and because it reveals whether a developer thinks about feedback speed, confidence, and maintainability together.

---

### The pyramid

```text
          /‾‾‾‾‾‾‾‾‾‾‾‾‾\
         /   E2E / System  \     ← fewest; slow; high confidence
        /‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\
       /  Integration / Request \  ← moderate number; medium speed
      /‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\
     /        Unit Tests          \  ← most; fast; isolated
    /‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\
```

**Invert the pyramid and you get the "ice cream cone" anti-pattern**: mostly slow E2E tests, few units, no integration. Suites that take 40 minutes to run, break on unrelated DOM changes, and give no guidance about *which layer* contains the bug.

The pyramid principle:

- **Write many small, fast, isolated unit tests** — they are cheap to write, cheap to run, and pinpoint failures exactly
- **Write a moderate layer of integration tests** — they verify that components fit together correctly
- **Write few end-to-end tests** — only for the critical happy paths that need confidence from top to bottom

---

### The four levels in Rails

| Level | Rails type | Gem | What it touches | Speed |
| --- | --- | --- | --- | --- |
| Unit | Model spec, service spec, validator spec, presenter spec | RSpec | A single class in isolation | ⚡ <10 ms each |
| Integration | Request spec | RSpec + `rack_test` | Full Rack stack: routes, controller, DB, serialiser | 🏃 ~100 ms each |
| Component | Controller spec | RSpec | Controller in isolation (deprecated by request specs) | 🏃 ~50 ms each |
| End-to-end | System spec / feature spec | RSpec + Capybara + Selenium/Cuprite | Full browser, JS, real HTTP server | 🐢 1–10 s each |

---

### Level 1 — Unit tests

Unit tests exercise **one class in isolation**. Dependencies are either stubbed or replaced with fakes. In Rails this means:

- **Model specs** — validations, associations, scopes, instance methods
- **Service object specs** — business logic, return values; collaborators stubbed
- **Validator specs** — the custom validator class alone
- **Presenter / decorator specs** — formatting methods
- **Job specs** — the `perform` method with `perform_now`
- **Mailer specs** — template rendering, recipients, subject

```ruby
# spec/models/issue_spec.rb — unit test
RSpec.describe Issue, type: :model do
  describe "validations" do
    it { is_expected.to validate_presence_of(:title) }
    it { is_expected.to validate_length_of(:title).is_at_most(255) }
  end

  describe "#closed?" do
    it "returns true when status is closed" do
      issue = build(:issue, status: :closed)
      expect(issue.closed?).to be true
    end
  end
end
```

**Rules:**

- No HTTP — do not call `get`, `post`, or visit any URL
- No integration with other services — stub mailers, jobs, external APIs
- Use `build` (not `create`) when you don't need persistence — no DB hit
- Fast enough that the full model spec suite runs in under 10 seconds

---

### Level 2 — Request specs (integration)

Request specs send a real HTTP request through the full Rack stack: router → middleware → controller → model → DB → serialiser → response. They replace controller specs (which are now officially discouraged by RSpec and the Rails core team).

```ruby
# spec/requests/issues_spec.rb — integration test
RSpec.describe "Issues API", type: :request do
  let(:project) { create(:project) }
  let(:issue)   { create(:issue, project: project) }

  describe "GET /projects/:id/issues/:id" do
    it "returns the issue as JSON" do
      get project_issue_path(project, issue), as: :json

      expect(response).to have_http_status(:ok)
      expect(json[:title]).to eq(issue.title)
    end

    it "returns 404 for a missing issue" do
      get project_issue_path(project, id: 0), as: :json
      expect(response).to have_http_status(:not_found)
    end
  end

  describe "POST /projects/:id/issues" do
    it "creates an issue and returns 201" do
      expect {
        post project_issues_path(project),
             params: { issue: { title: "New bug", author_name: "Alice", status: "open" } },
             as: :json
      }.to change(Issue, :count).by(1)

      expect(response).to have_http_status(:created)
    end

    it "returns 422 when title is blank" do
      post project_issues_path(project),
           params: { issue: { title: "", author_name: "Alice" } },
           as: :json

      expect(response).to have_http_status(:unprocessable_entity)
      expect(json[:title]).to include("can't be blank")
    end
  end

  private

  def json
    response.parsed_body.with_indifferent_access
  end
end
```

**What request specs cover that unit tests don't:**

- Routing (the correct controller action is wired to the path)
- Parameter filtering (`strong_parameters` doing its job)
- HTTP status codes and response headers
- JSON rendering (Jbuilder, serialisers)
- `before_action` callbacks and authentication filters
- Database round-trip (the record is actually persisted)

**What they don't cover:**

- JavaScript behaviour
- Real browser rendering
- Session cookies across page navigations (use system tests for that)

---

### Level 3 — System specs / feature specs (E2E)

System specs (RSpec `type: :system`) and feature specs (RSpec `type: :feature`) both use Capybara to drive a browser. They are effectively the same thing — `feature`/`scenario` are aliases for `describe`/`it` with `type: :feature` applied automatically.

**GitLab's naming convention** uses `type: :feature` for Capybara tests; Rails' own generator creates `type: :system`. Either works — choose one and be consistent.

```ruby
# spec/system/issues_spec.rb — E2E test
RSpec.describe "Creating an issue", type: :system do
  let(:project) { create(:project) }

  before { driven_by :selenium, using: :headless_chrome }

  it "lets a user create an issue and see it in the list" do
    visit new_project_issue_path(project)

    fill_in "Title",       with: "Login button broken"
    fill_in "Author name", with: "Alice"
    select  "Open",        from: "Status"
    click_on "Create Issue"

    expect(page).to have_content("Issue was successfully created")
    expect(page).to have_content("Login button broken")
  end
end
```

**When to write a system test instead of a request spec:**

| Situation | Use |
| --- | --- |
| Testing JavaScript interactions (Turbo, Stimulus, modals) | System test |
| Testing a full multi-step user flow (login → navigate → act → assert redirect) | System test |
| Testing form validation UX (error messages appear inline) | System test |
| Testing HTTP status codes, JSON shape, redirects | Request spec |
| Testing a controller filter or middleware | Request spec |
| Testing business logic that doesn't need a browser | Unit test or request spec |

---

### Controller specs — avoid them

Controller specs (`type: :controller`) test the controller in isolation using `get`/`post` helpers that bypass the router. They were the Rails 3/4 standard but have two problems:

1. They bypass routing — they don't catch misconfigured routes
2. They are less realistic than request specs (different middleware stack)

Both RSpec and the Rails core team now recommend **replacing controller specs with request specs**. New projects should not write controller specs at all.

---

### GitLab's testing approach

GitLab is one of the most tested Rails codebases in the world. Their [testing guide](https://docs.gitlab.com/development/testing_guide/) defines exactly what spec type to use for each situation:

#### GitLab's spec type rules

| GitLab name | RSpec type | When GitLab uses it |
| --- | --- | --- |
| Unit spec | `type: :model`, `:service`, `:worker`, `:validator`, `:presenter` | Single-class logic |
| Request spec | `type: :request` | JSON APIs, status codes, auth filters |
| Feature spec | `type: :feature` | Full browser flows with Capybara |
| Helper spec | `type: :helper` | View helpers |
| Routing spec | `type: :routing` | Named route correctness |
| GraphQL spec | `type: :request` | GraphQL queries and mutations |

GitLab explicitly states:

> "We have no controller specs. We use request specs for testing controllers."

> "Feature specs are expensive. We use them for critical paths only."

#### GitLab's test speed tiers

GitLab's CI pipeline groups tests into speed tiers:

| Tier | Max per-example | What it contains |
| --- | --- | --- |
| `~unit` | < 1 s | Model, service, worker, validator specs |
| `~integration` | < 5 s | Request specs, mailer specs |
| `~system` | < 30 s | Feature/system specs |

Any spec that exceeds its tier's budget is flagged in code review and must be optimised.

#### GitLab's shared examples pattern

GitLab uses RSpec shared examples extensively to avoid duplication across similar specs:

```ruby
# spec/support/shared_examples/a_valid_issue.rb
RSpec.shared_examples "a valid issue" do
  it { is_expected.to be_valid }
  it { is_expected.to validate_presence_of(:title) }
  it { is_expected.to belong_to(:project) }
end

# In any model spec:
RSpec.describe Issue, type: :model do
  subject { build(:issue) }
  it_behaves_like "a valid issue"
end
```

#### GitLab's factory discipline

GitLab's guide is explicit: **factories should build the minimum valid object**. Traits add associations on demand. Never use `create` when `build` is enough:

```ruby
# ✅ Minimum factory — no unnecessary associations
FactoryBot.define do
  factory :issue do
    sequence(:title) { |n| "Issue #{n}" }
    author_name { "Alice" }
    status      { :open }
    association :project
  end

  trait :closed do
    status { :closed }
  end

  trait :with_labels do
    after(:create) do |issue|
      issue.labels << create(:label)
    end
  end
end

# In a spec that needs closed + labels:
create(:issue, :closed, :with_labels)
```

#### GitLab's RSpec metadata tags

GitLab tags examples with metadata to control which suite they run in and which setup they need:

```ruby
it "sends an email", :mailer do ... end         # loads Action Mailer helpers
it "uses Redis cache", :use_clean_rails_redis_caching do ... end
it "is an API test", :api do ... end
it "runs in the background", :sidekiq_inline do ... end  # drains Sidekiq inline
```

---

### The decision flowchart — which spec type?

```text
Is this testing a single class with no HTTP?
  YES → unit spec (model / service / validator / presenter / job)

Does it need HTTP but no browser / no JS?
  YES → request spec

Does it need a real browser or JS?
  YES → system / feature spec

Is it testing a named route?
  YES → routing spec (or just test it implicitly in a request spec)

Is it testing a view helper method?
  YES → helper spec
```

**When feature specs beat request specs:**

1. **JavaScript is involved** — `rack_test` cannot run JS. If the flow requires Turbo, Stimulus, a modal, or an AJAX call that updates the DOM, you need a browser.
2. **Multi-step navigation** — a flow that spans multiple page loads (login → dashboard → click link → fill form → confirm redirect) is much cleaner as a feature spec than a chain of request specs.
3. **Visual feedback validation** — confirming that a flash message appears in the right place, an error is shown inline next to the correct field, or a badge changes colour is only possible with a browser.
4. **Acceptance criteria from a user story** — when the ticket says "as a user I can create an issue", a feature spec reads exactly like the acceptance criterion.

**When request specs beat feature specs:**

1. **JSON API behaviour** — response shape, status codes, headers. Capybara doesn't inspect HTTP status codes directly; request specs do.
2. **Authorization / authentication logic** — testing that a 401 or 403 is returned for the right conditions is cleaner in a request spec.
3. **Edge cases and error paths** — testing 20 different invalid input combinations in a browser is slow. One request spec per case is 100× faster.
4. **Middleware and filters** — `before_action`, rate limiting, content negotiation live at the HTTP layer, not the browser layer.

---

### Testing pyramid in this project

| Spec file | Type | Level |
| --- | --- | --- |
| `spec/models/issue_spec.rb` | `:model` | Unit |
| `spec/models/project_spec.rb` | `:model` | Unit |
| `spec/validators/no_profanity_validator_spec.rb` | `:model` | Unit |
| `spec/requests/issues_spec.rb` | `:request` | Integration |
| `spec/requests/projects_spec.rb` | `:request` | Integration |
| `spec/system/issues_spec.rb` | `:system` | E2E |

**Current split**: heavy on unit and request specs (fast, precise), light on system specs (only critical flows). This matches the pyramid and GitLab's own guidance.

---

### The Testing Pyramid — Interview Q&A

**Q: What is the testing pyramid and why does it matter?**
The testing pyramid says: write many unit tests (fast, isolated, cheap), a moderate layer of integration tests (verify components fit together), and few end-to-end tests (slow, expensive, but highest confidence). It matters because an inverted pyramid — lots of E2E tests, few units — creates suites that take 40+ minutes, break on unrelated UI changes, and give no guidance about where a bug lives. The pyramid maximises feedback speed while maintaining confidence.

**Q: What is the difference between a request spec and a system spec in Rails?**
A request spec (`type: :request`) uses `rack_test` to send HTTP requests directly to the Rack app — no browser, no JS. It's fast and precise for testing status codes, JSON shape, redirects, and authentication. A system spec (`type: :system`) drives a real browser via Capybara + Selenium/Cuprite — it tests JavaScript interactions, multi-page flows, and real browser rendering. System specs are 10–100× slower; use them only for critical user journeys that require a browser.

**Q: Why does the Rails community recommend request specs over controller specs?**
Controller specs (`type: :controller`) test the controller in isolation by bypassing the router. They use a different middleware stack from real requests, so they miss routing bugs and middleware behaviour. The RSpec team and the Rails core team both now recommend request specs, which go through the full Rack stack including routing, and produce more realistic results. New projects should have zero controller specs.

**Q: When would you choose a feature spec over a request spec?**
When the scenario requires JavaScript (Turbo frames, Stimulus controllers, modal dialogs, AJAX updates), spans multiple page navigations, or validates visual/UX behaviour (flash messages, inline errors, badge states). For anything that can be tested via HTTP alone — JSON shape, status codes, authentication filters, edge-case inputs — a request spec is faster, more precise, and the right choice.

**Q: How does GitLab structure its test suite?**
GitLab uses: unit specs for every service, model, validator, worker, and presenter; request specs for all API endpoints (no controller specs at all); feature specs for critical browser flows only. They enforce speed tiers (unit < 1s, integration < 5s, system < 30s per example) and flag violations in code review. They use shared examples to avoid duplication and FactoryBot traits to build minimum-valid objects.

**Q: What is the "ice cream cone" anti-pattern?**
The inverted testing pyramid. A codebase with mostly E2E/feature tests and few unit tests. Symptoms: the test suite takes 30–60 minutes, failures don't tell you which class is broken, a small CSS change breaks dozens of tests, and developers stop running the suite locally. The fix is to push coverage down the pyramid: extract business logic into service objects and unit-test those; use request specs for HTTP behaviour; reserve feature specs for the 5–10 most critical user journeys.

**Q: What is the `build` vs `create` distinction in FactoryBot and why does it matter for test speed?**
`create` persists the record to the database (INSERT). `build` instantiates the Ruby object without hitting the database. For unit tests that only need the object in memory (validations, method logic), `build` is correct — it avoids a DB round-trip and makes the test 10–50× faster. Using `create` everywhere is the most common cause of slow model spec suites.

---

## 29. Test Coverage — SimpleCov & the GitLab Approach

### What is test coverage?

**Test coverage** measures what percentage of your application code is
executed when the test suite runs. It is expressed as a ratio of
**lines hit** (or branches hit) to **total lines**.

Coverage is a **floor, not a ceiling** — 100% coverage does not mean
your tests are good, it only means every line was executed at least once.
But low coverage (< 80%) is a reliable signal that large swaths of code
are completely untested.

---

### SimpleCov — the standard Ruby coverage tool

**SimpleCov** wraps Ruby's built-in `Coverage` module with a friendly
DSL, HTML report generation, and per-group breakdowns.

#### Installation

```ruby
# Gemfile
group :test do
  gem "simplecov", require: false
end
```

#### Wiring it into spec_helper.rb

SimpleCov **must be started before Rails or any application code loads** —
otherwise files loaded before `SimpleCov.start` will not appear in the
report.

```ruby
# spec/spec_helper.rb — very first lines, before everything else
require "simplecov"

SimpleCov.start "rails" do
  # Fail the build if coverage drops below this threshold
  minimum_coverage 90

  # Exclude files that don't need coverage
  add_filter "/spec/"
  add_filter "/config/"
  add_filter "/db/"
  add_filter "/vendor/"

  # Group the report by layer
  add_group "Models",      "app/models"
  add_group "Controllers", "app/controllers"
  add_group "Helpers",     "app/helpers"
  add_group "Jobs",        "app/jobs"
  add_group "Mailers",     "app/mailers"
end

# ... rest of spec_helper.rb
```

The `"rails"` preset automatically excludes common noise (rake tasks,
initializers, db/migrate, etc.).

After running `bundle exec rspec`, SimpleCov writes:

```
coverage/index.html   ← open in browser for the full visual report
```

And prints to the terminal:

```
Coverage report generated for RSpec to /path/to/coverage/index.html.
73 / 80 LOC (91.25%) covered.
```

---

### How GitLab uses SimpleCov

GitLab configures SimpleCov with a regex that GitLab CI recognises to
populate the **coverage badge** and the **diff coverage panel** on merge
requests:

```yaml
# .gitlab-ci.yml
rspec:
  script:
    - bundle exec rspec
  coverage: '/LOC \((\d+\.\d+%)\) covered/'
```

The pipeline then shows:
- **Total coverage** on the pipeline page
- **Diff coverage** — only the lines added/changed in the MR — so reviewers
  can see at a glance whether new code is covered without looking at total
  coverage (which barely moves on a large codebase)

GitLab's target is **> 90% overall coverage** across the monorepo.

---

### Branch coverage vs line coverage

By default SimpleCov counts **line coverage** — was this line executed?
You can enable **branch coverage** (was each conditional path taken?):

```ruby
SimpleCov.start "rails" do
  enable_coverage :branch
  primary_coverage :branch  # fail threshold applies to branch %, not line %
  minimum_coverage line: 90, branch: 80
end
```

Branch coverage catches bugs that line coverage misses:

```ruby
def discount(user)
  return 0.2 if user.premium?  # ← line is hit, but what if premium? is false?
  0.0
end

# Line coverage: 100% if any test calls discount()
# Branch coverage: requires one test where user.premium? is true
#                  AND one where it is false
```

---

### Test quality tools GitLab uses beyond SimpleCov

| Tool | Purpose |
| --- | --- |
| **Knapsack Pro** | Splits the suite across parallel CI nodes by historical timing — reduces hours-long runs to ~15 min |
| **rspec-retry** | Retries flaky specs N times before failing — buys time to fix intermittent failures without blocking CI |
| **test-prof** | Profiles slow specs — identifies which factories, `let` chains, or DB calls are the bottleneck |
| **Crystalball** | Predictive test selection — maps changed files to affected specs; MR pipelines run only relevant tests |
| **Mutation testing** | Verifies tests actually catch bugs by mutating source code and checking if tests fail — run selectively on critical paths |

**test-prof** example — finding the slowest factories:

```bash
TEST_STACK_PROF=1 bundle exec rspec
# Prints a flamegraph showing where time is spent during the test run
```

---

### Adding SimpleCov to this project

```ruby
# Gemfile
group :test do
  gem "simplecov", require: false
end
```

```ruby
# spec/spec_helper.rb — insert at the very top, before RSpec.configure
require "simplecov"

SimpleCov.start "rails" do
  minimum_coverage 90
  add_filter "/spec/"
  add_filter "/config/"
  add_filter "/db/"
  add_group "Models",      "app/models"
  add_group "Controllers", "app/controllers"
  add_group "Jobs",        "app/jobs"
end
```

```bash
bundle install
bundle exec rspec
open coverage/index.html  # macOS
```

---

### Coverage — Interview Q&A

**Q: What is test coverage and what are its limits?**

> Coverage measures what percentage of code lines (or branches) are
> executed during the test run. Its limit: 100% coverage does not mean
> 100% correctness — a test that calls every line but makes no assertions
> has full coverage and zero value. Coverage is a useful floor (low
> coverage is bad) but a poor ceiling (high coverage is not a quality
> guarantee).

**Q: Why must SimpleCov be started before Rails loads?**

> Ruby's `Coverage` module only tracks files that are loaded *after*
> coverage tracking starts. If Rails and the application boot before
> `SimpleCov.start`, those files are never registered and will not appear
> in the report — giving a falsely optimistic coverage number.

**Q: What is diff coverage and why does GitLab use it on MRs?**

> Diff coverage shows coverage only for the lines added or changed in a
> merge request, ignoring the rest of the codebase. On a large repo the
> total coverage percentage barely moves when you add 50 lines — diff
> coverage makes the signal meaningful: "did the author cover their own
> changes?"

**Q: What is the difference between line coverage and branch coverage?**

> Line coverage records whether a line was executed at all. Branch
> coverage records whether each conditional path (both sides of an `if`,
> every `case` branch) was taken. Branch coverage catches untested logical
> paths that line coverage misses — a line with `if x; A; else; B; end`
> can be 100% line-covered if a test hits it, but 50% branch-covered if
> only one side is ever exercised.

**Q: What is Crystalball and how does it speed up GitLab's CI?**

> Crystalball builds a map of which spec files cover which application
> files by recording which files are loaded during each spec. On a new
> MR, it runs only the specs that cover the changed files, skipping the
> rest. For a 50,000-spec suite this can reduce a 60-minute run to a
> 5-minute targeted run on the MR pipeline, while the full suite still
> runs nightly.

---

## 30. Monitoring — Prometheus, Grafana, Sentry & the Observability Stack

### The three pillars of observability

A production system is observable if you can answer three questions from
external data alone:

| Pillar | Question answered | Tool |
| --- | --- | --- |
| **Metrics** | *What is happening right now, in numbers?* | Prometheus + Grafana |
| **Logs** | *What happened, in detail, for this request?* | ELK / Fluentd |
| **Traces** | *Why was this specific request slow?* | Jaeger / OpenTelemetry |

GitLab uses all three, and they are designed to complement each other:
metrics alert you that something is wrong, logs tell you what happened,
traces tell you where the time was spent.

---

### Metrics — Prometheus & Grafana

**Prometheus** scrapes metrics from every service on a regular interval
(typically 15 s) and stores them as time-series. Rails exposes metrics via
the `prometheus-client` gem through a `/metrics` Rack endpoint.

#### What GitLab exposes

```text
# Counters — monotonically increasing
gitlab_rails_requests_total{controller, action, format, status}
gitlab_rails_exceptions_total{exception_class}
sidekiq_jobs_processed_total{queue, worker}
sidekiq_jobs_failed_total{queue, worker}

# Histograms — latency distributions with buckets
gitlab_rails_sql_duration_seconds{bucket}
gitlab_rails_redis_client_duration_seconds{bucket}
gitlab_rails_cache_operation_duration_seconds{command, bucket}
gitlab_rails_request_duration_seconds{controller, action, bucket}

# Gauges — point-in-time values
gitlab_rails_active_connections
sidekiq_queue_size{queue}
sidekiq_queue_latency_seconds{queue}
```

#### Grafana dashboards

Grafana queries Prometheus with **PromQL** to build dashboards:

```promql
# p99 request latency for the last 5 minutes
histogram_quantile(0.99,
  rate(gitlab_rails_request_duration_seconds_bucket[5m])
)

# Error rate per second
rate(gitlab_rails_exceptions_total[1m])

# Sidekiq throughput — jobs per second
rate(sidekiq_jobs_processed_total[1m])
```

---

### The RED method — what GitLab tracks per service

The **RED method** (from Tom Wilkie at Weaveworks) defines the three
metrics every service should expose:

| Letter | Metric | What it means |
| --- | --- | --- |
| **R** | Rate | Requests per second |
| **E** | Errors | Failed requests per second (or %) |
| **D** | Duration | Latency distribution (p50, p95, p99) |

GitLab tracks these for every Rails controller action, every Sidekiq
worker, every Gitaly RPC call, and every Redis/database operation.

---

### SLOs — what GitLab commits to

| Metric | Target |
| --- | --- |
| Web p99 latency | < 1 s for most endpoints |
| API p99 latency | < 300 ms |
| Sidekiq job pick-up latency (critical queue) | < 10 s |
| Error rate | < 0.1% of requests |
| Availability | 99.95% (GitLab.com) |

When an SLO is breached, **Prometheus AlertManager** fires an alert to
**PagerDuty**, which pages the on-call engineer.

---

### Error tracking — Sentry

**Sentry** captures unhandled exceptions with full stack traces, request
context, user ID, and breadcrumbs. GitLab runs a self-hosted Sentry
instance.

```ruby
# Gemfile
gem "sentry-ruby"
gem "sentry-rails"
gem "sentry-sidekiq"

# config/initializers/sentry.rb
Sentry.init do |config|
  config.dsn                    = ENV["SENTRY_DSN"]
  config.breadcrumbs_logger     = [:active_support_logger, :http_logger]
  config.traces_sample_rate     = 0.1   # send 10% of transactions as traces
  config.profiles_sample_rate   = 0.1
  config.environment            = Rails.env
  config.release                = ENV["GIT_COMMIT_SHA"]
end
```

Sentry integrates with Sidekiq automatically — failed jobs appear with
their full context. It also supports **performance monitoring** (Sentry
Transactions), which overlap with Jaeger for tracing.

---

### Distributed tracing — Jaeger / OpenTelemetry

A single GitLab web request may touch: Rails → Redis → PostgreSQL →
Gitaly (Git operations) → Workhorse (file serving) → Registry. A trace
records a **span** for each hop, with timing and metadata.

```
Request: GET /project/repo/issues
│
├─ Rails router + middleware          2 ms
├─ ApplicationController#before_action  1 ms
├─ IssuesController#index
│   ├─ DB: SELECT issues WHERE ...   12 ms  ← slow
│   ├─ Redis: cache GET              0.4 ms
│   └─ View render                    8 ms
└─ Total                             24 ms
```

GitLab uses **OpenTelemetry** as the instrumentation standard (vendor-
neutral) and exports to Jaeger for storage and querying.

---

### Logging — structured JSON

Every Rails log line at GitLab is a **JSON object**, not a plain string:

```json
{
  "severity": "INFO",
  "time": "2026-03-30T14:00:00.000Z",
  "correlation_id": "abc123",
  "method": "GET",
  "path": "/api/v4/projects/1/issues",
  "status": 200,
  "duration_s": 0.045,
  "db_duration_s": 0.012,
  "redis_calls": 3,
  "user_id": 42,
  "project_id": 1
}
```

Structured logs can be queried, aggregated, and alerted on in
Elasticsearch. Plain-string logs cannot.

Rails produces plain-string logs by default. GitLab uses the
`lograge` gem to convert them:

```ruby
# Gemfile
gem "lograge"

# config/initializers/lograge.rb
Rails.application.configure do
  config.lograge.enabled = true
  config.lograge.formatter = Lograge::Formatters::Json.new
  config.lograge.custom_options = lambda do |event|
    {
      user_id:    event.payload[:user_id],
      request_id: event.payload[:request_id]
    }
  end
end
```

---

### The full GitLab monitoring stack

| Layer | Tool | Hosted how |
| --- | --- | --- |
| Metrics collection | Prometheus | Self-managed |
| Metrics visualisation | Grafana | Self-managed |
| Alerting | Prometheus AlertManager + PagerDuty | Managed |
| Error tracking | Sentry | Self-hosted |
| Distributed tracing | Jaeger + OpenTelemetry | Self-managed |
| Log shipping | Fluentd → Elasticsearch | Self-managed |
| Log querying | Kibana | Self-managed |
| Uptime / synthetic checks | Pingdom + internal probes | Managed |

---

### What this means for a Rails interview

When asked about monitoring in Rails, interviewers want to hear:

1. **The three pillars** — metrics (what), logs (what in detail), traces (why)
2. **The RED method** — rate, errors, duration — for services
3. **The USE method** — utilisation, saturation, errors — for infrastructure
4. **Actionability** — an alert without a runbook is noise; every metric should drive a decision

A minimal production Rails app needs at minimum:
- **Exception tracking** (Sentry or Honeybadger) — zero config, huge value
- **Request latency & error rate** (Skylight, Scout, or self-hosted Prometheus) 
- **Background job monitoring** (Sidekiq Web UI or Solid Queue dashboard)
- **Structured logs** (lograge) so log lines are searchable

---

### Monitoring — Interview Q&A

**Q: What are the three pillars of observability?**

> Metrics (what is happening, in numbers — Prometheus), logs (what
> happened for a specific request — ELK/Fluentd), and traces (why a
> specific request was slow across service boundaries — Jaeger/
> OpenTelemetry). Metrics alert you, logs explain what happened, traces
> show where time was spent.

**Q: What is the RED method?**

> Rate (requests per second), Errors (failed requests per second), Duration
> (latency distribution). It defines the three metrics every service should
> expose. GitLab tracks RED for every Rails controller action, Sidekiq
> worker, and downstream RPC call.

**Q: What does Sentry give you that logs don't?**

> Sentry groups identical exceptions together, tracks occurrence count and
> affected users, captures the full stack trace with local variable values,
> shows breadcrumbs leading up to the error, and alerts when a new
> exception class appears. Logs require you to search for errors
> reactively; Sentry surfaces them proactively.

**Q: Why use structured (JSON) logs instead of plain-string logs?**

> Structured logs are machine-readable — you can query `duration_s > 1.0`
> in Kibana, aggregate by `user_id`, or alert when `status: 500` exceeds a
> threshold. Plain-string logs require fragile regex parsing and can't be
> aggregated. GitLab uses `lograge` to convert Rails' default log format
> to JSON and ships every field (user ID, correlation ID, DB/Redis
> duration) as a queryable attribute.

**Q: What is a distributed trace and when do you need one?**

> A trace records the end-to-end journey of a single request through all
> the services it touches, with a timing span for each hop. You need
> distributed tracing when a request is slow but the bottleneck is not
> obvious from the Rails log alone — it might be a slow Gitaly RPC, a
> Redis call on a cold key, or an N+1 hidden inside a serialiser. A trace
> makes the breakdown visible in one view.

---
