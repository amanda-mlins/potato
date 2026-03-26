# Rails Interview Guide — Part 5: Architecture & Background Jobs

> Sections 25–26: Where Logic Lives, Background Jobs (ActiveJob & Solid Queue)

[← Back to index](README.md)

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

---

## 26. Background Jobs — ActiveJob & Solid Queue

Background jobs let a Rails app hand off slow or non-critical work — email delivery, webhook notifications, report generation, cache warm-ups — so that the HTTP response returns instantly. This section covers the full stack: the ActiveJob abstraction, Solid Queue (the Rails 8 default adapter), adapter configuration, job design, retries, idempotency, testing, and how GitLab approaches background work at scale.

---

### Why background jobs exist

A synchronous request-response cycle has a hard budget: the browser (or API client) is waiting. Anything that takes more than a few hundred milliseconds risks a timeout or a bad UX. Background jobs solve this by:

1. Returning the HTTP response immediately ("your report is being generated")
2. Enqueuing a job record in a persistent store (database, Redis, etc.)
3. Letting a separate worker process pick up and execute the job asynchronously

Rails provides **ActiveJob** as a unified interface, and as of Rails 8.0, **Solid Queue** ships as the default backend — a database-backed queue that requires no extra infrastructure (no Redis, no separate service).

---

### ActiveJob — the abstraction layer

ActiveJob is a wrapper around any queue backend. It defines a standard API so you can swap adapters without changing job code.

**Anatomy of a job:**

```ruby
# app/jobs/issue_close_notification_job.rb
class IssueCloseNotificationJob < ApplicationJob
  queue_as :default

  def perform(issue_id, closed_by_id)
    issue     = Issue.find(issue_id)
    closed_by = User.find(closed_by_id)
    IssueMailer.closed_notification(issue, closed_by).deliver_now
  end
end
```

**Enqueuing from a service object (never from a controller):**

```ruby
# app/services/issues/close_service.rb
module Issues
  class CloseService
    def initialize(issue:, current_user:)
      @issue        = issue
      @current_user = current_user
    end

    def execute
      @issue.update!(status: :closed)
      IssueCloseNotificationJob.perform_later(@issue.id, @current_user.id)
      ServiceResponse.success(payload: { issue: @issue })
    end
  end
end
```

**Why pass IDs, not objects?**

Jobs are serialised to JSON and stored in the queue. Active Record objects can't be serialised reliably — you'd get a stale object if the job runs after a deploy. Pass the ID and reload inside `perform`. ActiveJob's `GlobalID` support does this automatically for AR objects, but plain IDs are more explicit and interviewers often ask about this.

---

### Solid Queue — Rails 8's default adapter

Solid Queue was introduced alongside Rails 8. It stores jobs in your existing database (PostgreSQL, SQLite, MySQL) using three tables: `solid_queue_jobs`, `solid_queue_ready_executions`, and `solid_queue_claimed_executions`. No Redis required.

**How it works:**

| Concept | Solid Queue equivalent |
| --- | --- |
| Job record | Row in `solid_queue_jobs` |
| Ready to run | Row in `solid_queue_ready_executions` |
| Running now | Row in `solid_queue_claimed_executions` (advisory lock) |
| Failed | Row in `solid_queue_failed_executions` |
| Scheduled (future) | Row in `solid_queue_scheduled_executions` |

Workers poll the database, claim a job with a database lock (no race conditions), and delete the execution record on success. On failure the record moves to `solid_queue_failed_executions` for inspection and retry.

**Starting the worker in development:**

```bash
bin/jobs          # the Solid Queue worker process — already present in Rails 8 apps
# or
bundle exec rake solid_queue:start
```

**In production (`Procfile` / `kamal`):**

```text
web:    bundle exec puma -C config/puma.rb
worker: bundle exec rake solid_queue:start
```

---

### Adapter configuration

Rails 8 apps configure the queue adapter per-environment.

**`config/application.rb`** — set the default:

```ruby
config.active_job.queue_adapter = :solid_queue
```

**`config/queue.yml`** — Solid Queue worker configuration (queues, concurrency, polling interval):

```yaml
default: &default
  dispatchers:
    - polling_interval: 1
      batch_size: 500
  workers:
    - queues: "*"
      threads: 3
      polling_interval: 0.1

development:
  <<: *default

production:
  <<: *default
  workers:
    - queues: "default,mailers"
      threads: 5
      polling_interval: 0.5
    - queues: "low"
      threads: 2
      polling_interval: 2
```

**For tests — use the inline adapter** (runs jobs synchronously, no worker needed):

```ruby
# config/environments/test.rb
config.active_job.queue_adapter = :test
```

---

### Queue priorities

Jobs are assigned to named queues. Workers can be configured to only process certain queues, enabling priority lanes:

```ruby
class IssueCloseNotificationJob < ApplicationJob
  queue_as :mailers       # high-priority — user-facing email
end

class WeeklyReportJob < ApplicationJob
  queue_as :low           # low-priority — can wait
end

class DataExportJob < ApplicationJob
  queue_as :default
end
```

Name your queues to reflect business priority, not technical implementation. `mailers`, `default`, `low` is a common three-tier pattern.

---

### Retries and error handling

ActiveJob provides built-in retry DSL:

```ruby
class IssueCloseNotificationJob < ApplicationJob
  queue_as :mailers

  # Retry up to 5 times with exponential back-off; discard if the issue was deleted
  retry_on StandardError, wait: :polynomially_longer, attempts: 5
  discard_on ActiveRecord::RecordNotFound

  def perform(issue_id, closed_by_id)
    issue     = Issue.find(issue_id)     # raises RecordNotFound → discarded
    closed_by = User.find(closed_by_id)
    IssueMailer.closed_notification(issue, closed_by).deliver_now
  end
end
```

**`retry_on` options:**

| Option | Meaning |
| --- | --- |
| `wait: :exponentially_longer` | 2s, 4s, 8s, 16s… |
| `wait: :polynomially_longer` | 1s, 4s, 9s, 16s… (gentler) |
| `wait: 30.seconds` | Fixed interval |
| `attempts: N` | Max total attempts (including the first) |
| `jitter: 0.15` | Add randomness to avoid thundering herd |

**`discard_on`** — silently drop the job on these exceptions instead of retrying. Use for "this record no longer exists and there's nothing to do."

---

### Idempotency — the key design constraint

A job can be retried after a partial execution (network timeout mid-send, process crash after the DB write but before the email). This means **`perform` must be safe to run more than once with the same arguments**.

Strategies:

```ruby
# ✅ Guard with a database flag — only send if not already sent
def perform(issue_id, closed_by_id)
  issue = Issue.find(issue_id)
  return if issue.close_notification_sent?     # idempotency guard

  IssueMailer.closed_notification(issue, User.find(closed_by_id)).deliver_now
  issue.update_columns(close_notification_sent: true)
end

# ✅ Use find_or_create_by / upsert for write operations
def perform(project_id)
  AuditEvent.find_or_create_by!(
    target_type: "Project",
    target_id:   project_id,
    action:      "weekly_digest_sent",
    occurred_at: Date.current
  )
end

# ❌ Not idempotent — sends duplicate emails on retry
def perform(issue_id, closed_by_id)
  issue = Issue.find(issue_id)
  IssueMailer.closed_notification(issue, User.find(closed_by_id)).deliver_now
end
```

---

### Scheduling recurring jobs

Rails 8 / Solid Queue supports cron-style recurring jobs via `config/recurring.yml`:

```yaml
# config/recurring.yml
production:
  weekly_digest:
    class: WeeklyDigestJob
    schedule: "0 9 * * 1"       # every Monday 09:00 UTC
    queue: low

  stale_issue_cleanup:
    class: StaleIssueCleanupJob
    schedule: "0 2 * * *"       # daily at 02:00 UTC
    queue: default
    args: [30]                   # days_threshold
```

No cron daemon or Whenever gem required — Solid Queue's dispatcher handles scheduling from within the process.

---

### Job design rules — applied from GitLab's guide

GitLab's worker guidelines (from `docs.gitlab.com/development/sidekiq/`) translate directly to ActiveJob:

| Rule | Reason |
| --- | --- |
| Pass IDs, not objects | Objects serialise stale state; IDs always reload current data |
| Workers must be idempotent | Safe retries after partial failures |
| Workers must be backwards-compatible | Queue may contain jobs from previous release during a rolling deploy |
| Never change `perform` signature without a migration strategy | Old enqueued jobs have old argument shapes |
| Limit job duration | Long-running jobs hold a worker thread; break large batches into smaller jobs |
| Avoid DB transactions spanning the job boundary | The job itself is the unit of work |

**Backwards-compatibility example:**

```ruby
# Release 1: original signature
def perform(issue_id)
  # ...
end

# Release 2: need to add closed_by_id — use a default so old jobs still work
def perform(issue_id, closed_by_id = nil)
  # ...
end

# Release 3: closed_by_id is now always present — safe to remove the default
def perform(issue_id, closed_by_id)
  # ...
end
```

---

### Testing background jobs

**With the `:test` adapter (recommended for most tests):**

```ruby
# spec/jobs/issue_close_notification_job_spec.rb
RSpec.describe IssueCloseNotificationJob, type: :job do
  let(:project) { create(:project) }
  let(:issue)   { create(:issue, project: project, status: :closed) }
  let(:user)    { create(:user) }

  describe "#perform" do
    it "delivers a closed notification email" do
      expect {
        described_class.perform_now(issue.id, user.id)
      }.to change(ActionMailer::Base.deliveries, :count).by(1)
    end

    it "discards the job if the issue no longer exists" do
      expect {
        described_class.perform_now(0, user.id)   # ID 0 → RecordNotFound
      }.not_to raise_error
    end
  end
end
```

**Assert a job was enqueued (without running it):**

```ruby
# In a service spec
RSpec.describe Issues::CloseService do
  it "enqueues a notification job" do
    issue   = create(:issue, status: :open)
    user    = create(:user)

    expect {
      Issues::CloseService.new(issue: issue, current_user: user).execute
    }.to have_enqueued_mail(IssueMailer, :closed_notification)
    # or for a plain job:
    # .to have_enqueued_job(IssueCloseNotificationJob).with(issue.id, user.id)
  end
end
```

**`perform_enqueued_jobs` — run enqueued jobs inline in a test:**

```ruby
perform_enqueued_jobs do
  Issues::CloseService.new(issue: issue, current_user: user).execute
end
# Now assert side effects (emails, DB changes)
```

---

### Background jobs in this project

This project uses SQLite in development (Rails 8 default), so Solid Queue works out of the box. Here is how the background job stack maps onto the codebase:

| Concern | File |
| --- | --- |
| Queue adapter | `config/application.rb` — `:solid_queue` |
| Worker config | `config/queue.yml` |
| Recurring job schedule | `config/recurring.yml` |
| Start the worker | `bin/jobs` |
| Job base class | `app/jobs/application_job.rb` |
| (future) Close notification | `app/jobs/issue_close_notification_job.rb` |
| (future) Stale cleanup | `app/jobs/stale_issue_cleanup_job.rb` |

---

### Background Jobs — Interview Q&A

**Q: Why pass IDs to `perform` instead of ActiveRecord objects?**
Jobs are serialised to JSON when enqueued and may run minutes or hours later. An AR object serialised at enqueue time contains stale data by execution time. Passing the ID forces a fresh `find` inside `perform`, guaranteeing the job operates on the current state. ActiveJob's GlobalID support does this transparently for AR objects, but plain IDs make the intent explicit — and interviewers frequently ask about it.

**Q: What is Solid Queue and why does Rails 8 use it by default?**
Solid Queue is a database-backed queue adapter built by the Rails team for Rails 8. It stores jobs as rows in your existing database, so you need no additional infrastructure (no Redis, no separate process to manage). Workers claim jobs using database advisory locks, preventing duplicate processing. It supports priorities, scheduled jobs (cron-style), recurring tasks, and failed job inspection — all without leaving the database.

**Q: What is the difference between `perform_later` and `perform_now`?**
`perform_later` serialises the job and puts it in the queue — it returns immediately. A worker process picks it up and runs it asynchronously. `perform_now` runs the job synchronously in the current process, bypassing the queue. Use `perform_now` in tests and rare urgent cases; use `perform_later` everywhere else.

**Q: What does idempotency mean for a job and how do you achieve it?**
An idempotent job produces the same outcome regardless of how many times it is run with the same arguments. This matters because jobs can be retried after a partial failure (crash mid-execution, network timeout). Techniques: check a "done" flag in the database before doing work; use `upsert`/`find_or_create_by` instead of plain `create`; make email delivery conditional on a `sent_at` column being nil.

**Q: What is `retry_on` and when would you use `discard_on`?**
`retry_on ExceptionClass, wait: :polynomially_longer, attempts: 5` tells ActiveJob to re-enqueue the job with increasing delays when that exception is raised, up to `attempts` times. Use it for transient failures: network errors, rate limits, temporary service outages. `discard_on` silently drops the job when a specific exception occurs. Use it for "the record no longer exists and there is nothing to do" — typically `ActiveRecord::RecordNotFound`.

**Q: How do you test that a job is enqueued without actually running it?**
Use ActiveJob's test helpers with the `:test` adapter. `have_enqueued_job(MyJob).with(args)` asserts the job was placed in the queue. `perform_enqueued_jobs { ... }` runs all enqueued jobs inline within the block, allowing you to assert side effects. `perform_now` runs the job directly in the test process for unit-testing the job's `perform` method in isolation.

**Q: What is backwards compatibility for workers and why does it matter?**
During a rolling deploy or zero-downtime restart, the queue can contain jobs enqueued by the previous version of the code. If the new code changes the `perform` method signature (adds a required argument, removes one, reorders them), those old jobs will crash when the new worker tries to run them. The solution is a two-release migration: in release N add the new argument with a default value so old and new jobs both work; in release N+1 make the argument required.

**Q: How does Solid Queue handle recurring / scheduled jobs?**
Solid Queue's dispatcher process reads `config/recurring.yml` and enqueues jobs on the specified cron schedule. No external cron daemon or Whenever gem is needed. The dispatcher runs as part of the same worker process started by `bin/jobs`. Scheduled (future) jobs are stored in `solid_queue_scheduled_executions` and moved to the ready queue when their scheduled time arrives.

---

