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

## 27. Pagination — Pagy, Offset vs Cursor, and the JSON API Pattern

When a project accumulates thousands of issues, returning all of them in a single query is a reliability hazard: it bloats memory, slows response time, and can time out the request entirely. Pagination is the standard solution. This section covers the strategies, the recommended gem, and the concrete implementation in this project.

---

### The two pagination strategies

#### Offset pagination (page-based)

The database skips a fixed number of rows and returns the next N:

```sql
SELECT * FROM issues ORDER BY created_at DESC LIMIT 25 OFFSET 500;
```

- **Pros**: simple, maps naturally to `?page=N` URLs, easy to link to arbitrary pages
- **Cons**: `OFFSET 500` makes the database scan and discard 500 rows on every query — performance degrades linearly as you page deeper. Also suffers from "page drift": if a record is inserted or deleted between page requests, records can shift and appear twice or be skipped.

#### Keyset / cursor pagination

Instead of skipping rows, the query uses a pointer (the last seen primary key or timestamp) as the WHERE clause:

```sql
SELECT * FROM issues
WHERE created_at < '2026-01-01 12:00:00'
   OR (created_at = '2026-01-01 12:00:00' AND id < 1234)
ORDER BY created_at DESC, id DESC
LIMIT 25;
```

- **Pros**: O(1) at any depth (uses the index directly), no page drift, stable under inserts/deletes
- **Cons**: no random-access (can't jump to page 47), harder to implement, requires a stable sort column with an index

**When to use which:**

| Situation | Use |
| --- | --- |
| Admin UI with page numbers | Offset (Pagy default) |
| Infinite scroll / "load more" | Cursor (Pagy's `Pagy::Keyset`) |
| Public API consumed by mobile apps | Cursor preferred |
| Simple internal tool, < 100k rows | Offset — simpler, fast enough |
| Feed or timeline at scale | Cursor — required |

---

### Why Pagy — not Kaminari or will_paginate

Three gems exist. Here is the comparison:

| | Pagy | Kaminari | will_paginate |
| --- | --- | --- | --- |
| Approach | Separate object, no model pollution | Extends ActiveRecord scope chain | Extends ActiveRecord scope chain |
| Memory | Minimal — no extra AR objects | Loads count query on every page | Loads count query on every page |
| Speed | ~40× faster than Kaminari (benchmark) | Baseline | Comparable to Kaminari |
| Offset pagination | ✅ | ✅ | ✅ |
| Keyset / cursor | ✅ `Pagy::Keyset` | ❌ | ❌ |
| JSON metadata helper | ✅ `pagy_metadata` | Manual | Manual |
| Used by GitLab | ✅ | ❌ (migrated away) | ❌ |
| Rails 8 compatible | ✅ | ✅ | ✅ |

Pagy keeps the pagination logic in a plain Ruby object (`Pagy`) rather than extending your models with scopes. This means your model stays clean, the page size is controlled by the controller, and the helper is available wherever you include it.

---

### Implementation in this project

#### 1. Gemfile

```ruby
gem "pagy", "~> 9.0"
```

#### 2. `config/initializers/pagy.rb`

```ruby
require "pagy/extras/metadata"  # pagy_metadata for JSON responses
require "pagy/extras/overflow"  # graceful handling of out-of-range pages

Pagy::DEFAULT[:limit]    = 25          # records per page
Pagy::DEFAULT[:overflow] = :last_page  # ?page=9999 → redirects to last page
```

#### 3. `app/controllers/application_controller.rb`

```ruby
class ApplicationController < ActionController::Base
  include Pagy::Backend   # adds the pagy() method to all controllers
end
```

#### 4. `app/helpers/application_helper.rb`

```ruby
module ApplicationHelper
  include Pagy::Frontend  # adds pagy_nav() and pagy_metadata() to all views
end
```

#### 5. `app/controllers/issues_controller.rb` — the index action

```ruby
def index
  # pagy() wraps the relation, runs COUNT(*) + SELECT with LIMIT/OFFSET,
  # and returns a [Pagy, ActiveRecord::Relation] pair
  @pagy, @issues = pagy(@project.issues.with_labels.recent, limit: 25)

  respond_to do |format|
    format.html
    format.json  # → app/views/issues/index.json.jbuilder
  end
end
```

`pagy()` reads `params[:page]` automatically. It runs two queries:

1. `SELECT COUNT(*) FROM issues WHERE project_id = ?` — total count for nav rendering
2. `SELECT * FROM issues WHERE project_id = ? ORDER BY created_at DESC LIMIT 25 OFFSET 0`

**Critical: always order before paginating.** Without `ORDER BY`, the database returns rows in an arbitrary, non-deterministic order — different rows can appear on different pages across requests.

#### 6. `app/views/issues/index.html.erb`

```erb
<% @issues.each do |issue| %>
  <%# render each row ... %>
<% end %>

<%# renders <nav> with prev/next + numbered page links %>
<%== pagy_nav(@pagy) %>

<p>
  Showing <%= @pagy.from %>–<%= @pagy.to %> of <%= @pagy.count %> issues
</p>
```

`<%==` (double equals) renders the HTML unescaped — required for Pagy's nav markup.

#### 7. `app/views/issues/index.json.jbuilder` — JSON envelope with metadata

```ruby
json.pagination do
  json.current_page @pagy.page
  json.total_pages  @pagy.last
  json.total_count  @pagy.count
  json.per_page     @pagy.limit
  json.next_page    @pagy.next   # nil on last page
  json.prev_page    @pagy.prev   # nil on first page
end

json.issues @issues do |issue|
  json.id          issue.id
  json.title       issue.title
  json.status      issue.status
  json.author_name issue.author_name
  json.created_at  issue.created_at
  json.labels      issue.labels.map(&:name)
  json.url         issue_url(issue)
end
```

**Example response:**

```json
{
  "pagination": {
    "current_page": 2,
    "total_pages": 12,
    "total_count": 291,
    "per_page": 25,
    "next_page": 3,
    "prev_page": 1
  },
  "issues": [...]
}
```

Clients use `pagination.next_page` to construct `?page=3` for the next request, and `pagination.total_pages` to know when to stop. This is the GitHub API and GitLab API pattern.

---

### Keyset pagination with `Pagy::Keyset` (for scale)

For infinite-scroll UIs or high-volume APIs, switch to keyset pagination. No count query, no page drift, O(1) at any depth:

```ruby
# Controller — keyset mode
def index
  @pagy, @issues = pagy_keyset(
    @project.issues.with_labels.order(:created_at, :id),
    limit: 25
  )
  respond_to { |f| f.json }
end
```

The response includes an opaque `next_cursor` token instead of a page number:

```json
{
  "pagination": {
    "next_cursor": "eyJjcmVhdGVkX2F0IjoiMjAyNi0wMS0wMSIsImlkIjoxMjM0fQ==",
    "per_page": 25
  },
  "issues": [...]
}
```

The client passes `?cursor=eyJ...` to get the next page. There is no `total_pages` or `total_count` — that requires a `COUNT(*)`, which is what keyset avoids.

---

### N+1 and pagination — the critical interaction

Eager-loading is even more important with pagination. Without `includes`, every row in the 25-issue page fires a separate query for its labels:

```ruby
# ❌ 1 + 25 queries (1 for issues, 1 per issue for labels)
@pagy, @issues = pagy(@project.issues.recent)

# ✅ 2 queries total (1 for issues, 1 for all their labels)
@pagy, @issues = pagy(@project.issues.with_labels.recent)
```

`scope :with_labels, -> { includes(:labels) }` is already defined in the `Issue` model. Always compose it before calling `pagy()`.

---

### Testing pagination

```ruby
# spec/requests/issues_spec.rb
RSpec.describe "Issues", type: :request do
  let(:project) { create(:project) }

  before { create_list(:issue, 30, project: project) }

  describe "GET /projects/:id/issues" do
    it "paginates to 25 per page by default" do
      get project_issues_path(project), as: :json

      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body["issues"].length).to eq(25)
      expect(body["pagination"]["total_count"]).to eq(30)
      expect(body["pagination"]["total_pages"]).to eq(2)
      expect(body["pagination"]["next_page"]).to eq(2)
    end

    it "returns the second page" do
      get project_issues_path(project), params: { page: 2 }, as: :json

      body = response.parsed_body
      expect(body["issues"].length).to eq(5)
      expect(body["pagination"]["current_page"]).to eq(2)
      expect(body["pagination"]["next_page"]).to be_nil
    end

    it "returns the last page for out-of-range page numbers" do
      get project_issues_path(project), params: { page: 999 }, as: :json

      body = response.parsed_body
      expect(body["pagination"]["current_page"]).to eq(body["pagination"]["total_pages"])
    end
  end
end
```

---

### Where pagination logic lives

Pagination sits in the controller — it is an HTTP/presentation concern, not a domain concern:

```text
Controller     → pagy(@scope)          decides page size, reads params[:page]
Model scope    → .with_labels.recent   owns ordering + eager-loading
Jbuilder view  → json.pagination       owns JSON representation
HTML view      → pagy_nav(@pagy)       owns navigation markup
```

**Do not** put `pagy` calls in service objects or models. The model does not know about HTTP request params. The service object does not know about page size. The controller is the right place.

---

### Pagination — Interview Q&A

**Q: What is the performance problem with offset pagination at large page numbers?**
`OFFSET N` forces the database to scan and discard the first N rows before returning results — even though those rows are never returned to the caller. This means a request for page 400 with 25 rows per page scans 10,000 rows. Execution time grows linearly with page depth. The index helps with ordering but cannot skip the offset scan. Keyset pagination avoids this entirely by using a `WHERE id < last_seen_id` clause that uses the index directly.

**Q: Why do you need an ORDER BY clause when paginating?**
Without a deterministic order, the database returns rows in heap order, which can change between requests as rows are inserted, updated, or vacuumed. A row can appear on two consecutive pages or be skipped entirely. `ORDER BY created_at DESC, id DESC` guarantees a stable, repeatable sort. The secondary sort on `id` breaks ties when multiple rows share the same `created_at` timestamp.

**Q: What does Pagy return from its `pagy()` method?**
A two-element array: a `Pagy` object containing metadata (current page, total pages, total count, limit, next/prev page numbers) and the paginated `ActiveRecord::Relation` that has `LIMIT` and `OFFSET` applied. The relation is still lazy — the database query doesn't run until you iterate it in the view.

**Q: How do you expose pagination metadata in a JSON API?**
Include `pagy/extras/metadata` in the initializer, then in the Jbuilder template build a `pagination` envelope with `@pagy.page`, `@pagy.last`, `@pagy.count`, `@pagy.next`, and `@pagy.prev`. Clients use `next_page` to construct the URL for the next request. `nil` for `next_page` signals the last page. This matches the GitHub/GitLab pagination API convention.

**Q: When would you use keyset pagination instead of offset?**
When the collection can be very large (millions of rows), when the UI uses infinite scroll rather than numbered pages, or when the API is consumed by mobile clients that can't tolerate the performance degradation of deep offsets. Keyset pagination is O(1) at any depth but cannot provide a total page count or allow jumping to an arbitrary page — those require a `COUNT(*)` which keyset deliberately avoids.

**Q: Why is Pagy preferred over Kaminari in modern Rails apps?**
Pagy is a plain Ruby object — it does not extend ActiveRecord models with scopes or add instance methods. It is roughly 40× faster and uses significantly less memory because it does not load or decorate AR objects for pagination purposes. It supports both offset and keyset strategies, provides a JSON metadata helper out of the box, and is what GitLab itself uses.

---

## 28. Concurrency in Rails — Threads, Processes, Locks & Race Conditions

### 28.1 The Rails concurrency model — Puma

Rails ships with **Puma** as its default web server. Puma uses a
**multi-threaded, multi-process** model:

```text
┌─────────────────── OS process (Puma worker) ───────────────────┐
│                                                                  │
│  Thread 1 ──► handles request A (waiting on DB query)           │
│  Thread 2 ──► handles request B (rendering view)                │
│  Thread 3 ──► handles request C (writing to Redis)              │
│  Thread 4 ──► idle                                              │
│  Thread 5 ──► idle                                              │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
         ×  (number of workers / WEB_CONCURRENCY)
```

**Threads** within one process share memory — fast, low overhead, but
require thread-safe code. **Workers** (processes) are copies of the entire
app — isolated memory, more RAM, but simpler safety guarantees.

The defaults in `config/puma.rb`:

```ruby
# config/puma.rb
threads_count = ENV.fetch("RAILS_MAX_THREADS", 5).to_i
threads threads_count, threads_count   # min, max threads per worker

workers ENV.fetch("WEB_CONCURRENCY", 2).to_i  # processes (cluster mode)

preload_app!   # fork after loading the app — saves RAM via copy-on-write
```

**Rule of thumb**: Set `RAILS_MAX_THREADS` equal to your database
connection pool size (they are coupled — each thread needs its own
connection). Set `WEB_CONCURRENCY` based on available RAM:
roughly `RAM / per-process-RAM`.

---

### 28.2 Thread safety in Rails

Rails itself is thread-safe as of Rails 4. The critical rule:

> **Never store mutable state in global or class-level variables.**

```ruby
# UNSAFE — all threads share @@count
class IssuesController < ApplicationController
  @@count = 0
  def index
    @@count += 1   # race condition: read-increment-write is not atomic
  end
end

# SAFE — instance variables are per-request (each request is one object)
class IssuesController < ApplicationController
  def index
    @count = Issue.count   # local to this request's controller instance
  end
end
```

| Storage | Thread-safe? | Scope |
| --- | --- | --- |
| Instance variables (`@var`) | ✅ | Per request (controller instance) |
| Local variables | ✅ | Per method call |
| `Thread.current[:key]` | ✅ | Per thread |
| Class variables (`@@var`) | ❌ | Shared across all threads |
| Constants mutated at runtime | ❌ | Shared across all threads |
| `Rails.cache` | ✅ | Thread-safe by design |

**`Thread.current`** is a safe way to pass per-request data (e.g. current
user) across layers without passing it as a method argument:

```ruby
# In ApplicationController:
before_action { Thread.current[:current_user] = current_user }
after_action  { Thread.current[:current_user] = nil }  # always clean up

# In a service object or model:
user = Thread.current[:current_user]
```

---

### 28.3 The database connection pool

Each Puma thread needs its own database connection. ActiveRecord manages a
**connection pool** — a fixed set of persistent connections shared across
threads within one process.

```yaml
# config/database.yml
production:
  pool: <%= ENV.fetch("RAILS_MAX_THREADS", 5) %>
```

**Pool size must equal `RAILS_MAX_THREADS`**. If it's smaller, threads
block waiting for a free connection — you get `ActiveRecord::ConnectionTimeoutError`.
If it's larger, you waste DB server resources.

```ruby
# Check pool status from console:
ActiveRecord::Base.connection_pool.stat
# => { size: 5, connections: 3, busy: 2, dead: 0, idle: 1, waiting: 0, checkout_timeout: 5.0 }
```

When running background jobs alongside Puma (e.g. Solid Queue in the same
process), both compete for the same pool — size it accordingly.

---

### 28.4 Race conditions — the classic example

Two users simultaneously close the same issue:

```text
Thread A                          Thread B
────────                          ────────
issue = Issue.find(1)             issue = Issue.find(1)
  # status: :open                   # status: :open
issue.update!(status: :closed)
                                  issue.update!(status: :closed)
                                  # no error — double-write, data looks fine
                                  # but callbacks / side-effects ran twice
```

If "closing an issue" triggers a notification job, the notification fires
twice. Rails gives you two tools to prevent this.

---

### 28.5 Optimistic locking — for low-contention conflicts

**Optimistic locking** assumes conflicts are rare. It lets concurrent reads
proceed freely but detects a conflict at write time by comparing a version
counter.

**Setup**: add a `lock_version` integer column (Rails detects it
automatically):

```ruby
# Migration
add_column :issues, :lock_version, :integer, default: 0, null: false
```

```ruby
# No code change needed in the model — AR handles it automatically
issue_a = Issue.find(1)  # lock_version: 5
issue_b = Issue.find(1)  # lock_version: 5

issue_a.update!(status: :closed)  # UPDATE ... SET lock_version = 6 WHERE lock_version = 5
# ✅ succeeds — lock_version in DB was 5

issue_b.update!(status: :closed)  # UPDATE ... SET lock_version = 6 WHERE lock_version = 5
# ❌ raises ActiveRecord::StaleObjectError — lock_version in DB is now 6
```

Handle the conflict in the controller:

```ruby
def update
  @issue.update!(issue_params)
rescue ActiveRecord::StaleObjectError
  @issue.reload
  flash.now[:alert] = "This issue was modified by someone else. Please review and retry."
  render :edit, status: :conflict
end
```

**When to use**: edit forms, APIs where clients fetch-then-update, any
multi-user editing scenario. Low overhead — just one extra integer column.

---

### 28.6 Pessimistic locking — for high-contention or critical sections

**Pessimistic locking** acquires a database row lock immediately (`SELECT
... FOR UPDATE`), blocking any other transaction from reading or writing
the locked rows until the lock is released.

```ruby
# Lock a single row:
Issue.transaction do
  issue = Issue.lock.find(1)
  # Any other transaction calling Issue.lock.find(1) will wait here
  issue.update!(status: :closed)
end  # lock released at COMMIT
```

**`with_lock` — convenience shorthand**:

```ruby
issue.with_lock do
  # issue is reloaded and locked for the duration of this block
  issue.update!(status: :closed)
  NotificationJob.perform_later(issue)
end
```

**Variants**:

```ruby
Issue.lock("FOR UPDATE SKIP LOCKED")  # skip rows already locked — for job queues
Issue.lock("FOR SHARE")               # allow concurrent reads, block writes
```

| | Optimistic | Pessimistic |
| --- | --- | --- |
| **Mechanism** | Version counter checked at write | DB row lock on SELECT |
| **Contention** | Low — optimistic about conflicts | High — blocks concurrent access |
| **User experience** | Error shown after the fact | Second user waits (or times out) |
| **Best for** | Edit forms, APIs | Financial transactions, job dispatch, inventory |
| **Risk** | Retry logic needed | Deadlocks if locks acquired in inconsistent order |

---

### 28.7 Atomic database operations — counters and `update_all`

For simple numeric updates, skip Ruby entirely — use atomic SQL:

```ruby
# UNSAFE — read-modify-write in Ruby across two queries
issue.update!(view_count: issue.view_count + 1)

# SAFE — single atomic SQL UPDATE, no race condition
Issue.where(id: issue.id).update_all("view_count = view_count + 1")

# Or with ActiveRecord counter cache:
Issue.increment_counter(:view_count, issue.id)
```

**Counter caches** — automatically maintained by Rails for `belongs_to`:

```ruby
class Issue < ApplicationRecord
  belongs_to :project, counter_cache: true
end
# Adds project.issues_count — updated atomically on create/destroy
```

---

### 28.8 Concurrency in background jobs — Solid Queue & Sidekiq

Solid Queue runs workers as separate processes or threads. Race conditions
apply equally to jobs. The most common pattern: use `with_lock` at the
start of a job to ensure only one worker processes a given record:

```ruby
class CloseIssueJob < ApplicationJob
  def perform(issue_id)
    Issue.find(issue_id).with_lock do |issue|
      return if issue.closed?  # idempotency check inside the lock
      issue.update!(status: :closed)
      NotificationMailer.issue_closed(issue).deliver_later
    end
  end
end
```

This pattern is also called **"check-then-act inside a lock"** — the
`closed?` check and the update are atomic.

---

### 28.9 Concurrency — Interview Q&A

**Q: How does Puma handle concurrent requests?**

> Puma uses a thread pool (default 5 threads per process) and optionally
> multiple worker processes. Threads within one process share memory and
> handle I/O-bound waiting efficiently (a thread blocked on a DB query
> yields the CPU to another thread). Workers provide full process
> isolation. The thread count must match the database connection pool size
> — each thread needs its own connection.

**Q: What makes code thread-unsafe in Rails?**

> Mutable state stored in class variables (`@@var`), global variables, or
> constants mutated at runtime. These are shared across all threads. Instance
> variables (`@var`) are safe because each request gets a new controller
> instance. Rails itself is thread-safe since Rails 4 — the danger is in
> application code, not the framework.

**Q: What is the difference between optimistic and pessimistic locking?**

> Optimistic locking adds a `lock_version` integer column. Reads are free;
> writes check that the version hasn't changed since the record was read. If
> it has, `ActiveRecord::StaleObjectError` is raised and the caller must
> retry. Pessimistic locking uses `SELECT FOR UPDATE` to hold a DB row lock
> for the entire transaction duration — other transactions block until it
> releases. Optimistic is better for low-contention UI forms; pessimistic
> is better for high-contention financial or inventory operations.

**Q: How do you make a counter increment thread-safe in Rails?**

> Use `update_all("counter = counter + 1")` or `increment_counter` — both
> translate to a single atomic `UPDATE` SQL statement. The Ruby pattern
> `record.update!(count: record.count + 1)` is a read-modify-write across
> two round-trips and is not atomic under concurrent access.

**Q: What is a deadlock and how do you avoid it?**

> A deadlock occurs when transaction A holds lock 1 and waits for lock 2,
> while transaction B holds lock 2 and waits for lock 1 — neither can
> proceed. Avoid it by always acquiring locks in the same order across all
> code paths (e.g. always lock `project` before `issue`, never the
> reverse), keeping transactions short, and using `SKIP LOCKED` for job
> queues so workers skip rows already held by another worker.

---

## 29. Authentication & Authorization — Devise, Pundit & the GitLab Model

### 29.1 The difference

| Concept | Question answered | "Who are you?" |
| --- | --- | --- |
| **Authentication** | *Who are you?* | Prove identity — login, session, token |
| **Authorization** | *What are you allowed to do?* | Enforce permissions — roles, policies |

They are entirely separate concerns. A system can identify you perfectly
(authentication) while giving you access to everything (no authorization).
Always implement them as separate layers.

---

### 29.2 Authentication strategies

#### Session-based (HTML apps) — Devise

**Devise** is the de-facto Rails authentication gem. It provides:

- Database-backed `User` model with hashed passwords (`bcrypt`)
- Session cookie management
- Registration, login, logout, password reset flows
- Email confirmation, account locking, rememberable ("remember me")

```ruby
# Gemfile
gem "devise"

# Terminal
rails generate devise:install
rails generate devise User
rails db:migrate
```

This generates a `User` model and wires up routes automatically:

```ruby
# config/routes.rb — added by Devise
devise_for :users
# Creates: /users/sign_in, /users/sign_up, /users/password/new, etc.
```

**Protecting controllers** with Devise:

```ruby
class ApplicationController < ActionController::Base
  before_action :authenticate_user!  # Devise helper — redirects to sign_in if not logged in
end

# Or selectively:
class IssuesController < ApplicationController
  before_action :authenticate_user!, except: [:index, :show]
end
```

**Accessing the current user** (Devise provides this automatically):

```ruby
current_user          # => User instance or nil
user_signed_in?       # => true / false
```

#### Token-based (JSON APIs) — Bearer tokens

For JSON API clients (mobile apps, third-party integrations), session
cookies are impractical. Use **Bearer tokens** instead:

```ruby
# A simple personal access token pattern (no gem needed):
class ApiToken < ApplicationRecord
  belongs_to :user
  before_create { self.token = SecureRandom.hex(32) }
end

# In ApplicationController (API namespace):
class Api::V1::ApplicationController < ActionController::API
  before_action :authenticate_token!

  private

  def authenticate_token!
    token = request.headers["Authorization"]&.delete_prefix("Bearer ")
    @current_user = ApiToken.find_by(token: token)&.user
    render json: { error: "Unauthorized" }, status: :unauthorized unless @current_user
  end
end
```

**JWT (JSON Web Tokens)** — an alternative to DB-stored tokens:

| | DB-stored tokens | JWT |
| --- | --- | --- |
| **Revocability** | ✅ Delete the row | ❌ Cannot revoke before expiry |
| **Stateless** | ❌ Requires DB lookup | ✅ Self-contained |
| **Rotation** | Simple | Complex |
| **Recommendation** | Prefer for most apps | Only when truly stateless |

GitLab uses DB-stored personal access tokens, not JWT, for its API.
JWT's irrevocability is a security liability — if a token is stolen,
you cannot invalidate it without a blocklist (which defeats the point).

#### HTTP Basic Auth — for internal/admin endpoints

```ruby
class AdminController < ApplicationController
  http_basic_authenticate_with name: ENV["ADMIN_USER"], password: ENV["ADMIN_PASSWORD"]
end
```

---

### 29.3 Adding authentication to this project

This project currently has no `User` model. Here is the full addition path:

```ruby
# 1. Gemfile
gem "devise"

# 2. Terminal
rails generate devise:install
rails generate devise User
rails db:migrate

# 3. Associate issues with their creator
rails generate migration AddUserToIssues user:references
rails db:migrate
```

```ruby
# 4. app/models/user.rb — generated by Devise
class User < ApplicationRecord
  devise :database_authenticatable, :registerable,
         :recoverable, :rememberable, :validatable
  has_many :issues, foreign_key: :author_id
end

# 5. app/models/issue.rb — add the association
class Issue < ApplicationRecord
  belongs_to :project
  belongs_to :author, class_name: "User"
  # ...
end

# 6. app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  include Pagy::Backend
  before_action :authenticate_user!
end

# 7. app/controllers/issues_controller.rb — set author on create
def create
  @issue = @project.issues.new(issue_params)
  @issue.author = current_user
  # ...
end
```

---

### 29.4 Authorization — Pundit

Once you know *who* the user is, you need to enforce *what they can do*.
**Pundit** is the standard Rails authorization gem — it uses plain Ruby
policy objects, one per model.

```ruby
# Gemfile
gem "pundit"

# app/controllers/application_controller.rb
class ApplicationController < ActionController::Base
  include Pundit::Authorization
  after_action :verify_authorized, except: :index
  after_action :verify_policy_scoped, only: :index
end
```

`verify_authorized` raises `Pundit::AuthorizationNotPerformedError` if you
forget to call `authorize` in an action — a safety net that prevents
accidentally unprotected endpoints.

#### Policy objects

```ruby
# app/policies/issue_policy.rb
class IssuePolicy < ApplicationPolicy
  # attr_reader :user, :record — provided by ApplicationPolicy

  def index?
    true  # anyone can list issues
  end

  def show?
    true  # anyone can view an issue
  end

  def create?
    user.present?  # must be logged in
  end

  def update?
    user.present? && (record.author == user || user.admin?)
  end

  def destroy?
    update?  # same rule as update
  end

  # Scope — filters which records the user can see
  class Scope < ApplicationPolicy::Scope
    def resolve
      if user&.admin?
        scope.all
      elsif user.present?
        scope.where(project: user.accessible_projects)
      else
        scope.none
      end
    end
  end
end
```

Pundit's `ApplicationPolicy` base class is generated by:

```bash
rails generate pundit:install
```

It gives you `user` (the current user) and `record` (the model instance)
as instance variables in every policy.

#### Using policies in controllers

```ruby
class IssuesController < ApplicationController
  def show
    authorize @issue        # calls IssuePolicy#show? — raises if denied
    # ...
  end

  def update
    authorize @issue        # calls IssuePolicy#update?
    @issue.update!(issue_params)
    # ...
  end

  def index
    @issues = policy_scope(@project.issues.with_labels.recent)
    # calls IssuePolicy::Scope#resolve — returns filtered relation
    @pagy, @issues = pagy(@issues, limit: 25)
  end

  def destroy
    authorize @issue        # calls IssuePolicy#destroy?
    @issue.destroy!
    # ...
  end
end
```

If `authorize` fails it raises `Pundit::NotAuthorizedError`. Handle it
globally:

```ruby
# app/controllers/application_controller.rb
rescue_from Pundit::NotAuthorizedError do |e|
  respond_to do |format|
    format.html { redirect_to root_path, alert: "You are not authorized to do that." }
    format.json { render json: { error: "Forbidden" }, status: :forbidden }
  end
end
```

---

### 29.5 Role systems

#### Simple role column

```ruby
# Migration
add_column :users, :role, :integer, default: 0, null: false

# Model
class User < ApplicationRecord
  enum :role, { viewer: 0, member: 1, maintainer: 2, admin: 3 }
end

# Policy
def update?
  user.admin? || user.maintainer? && record.project.members.include?(user)
end
```

#### Resource-scoped roles (GitLab's model)

GitLab uses a **membership** join table — a user's role is scoped per
project/group, not global:

```ruby
class Membership < ApplicationRecord
  belongs_to :user
  belongs_to :project
  enum :access_level, { guest: 10, reporter: 20, developer: 30,
                         maintainer: 40, owner: 50 }
end

class Project < ApplicationRecord
  has_many :memberships
  has_many :members, through: :memberships, source: :user
end

class User < ApplicationRecord
  has_many :memberships
  has_many :projects, through: :memberships

  def role_in(project)
    memberships.find_by(project: project)&.access_level
  end

  def can_edit_issues_in?(project)
    level = role_in(project)
    Membership.access_levels[level] >= Membership.access_levels["developer"]
  end
end
```

This is the pattern your issue tracker would use if you wanted per-project
permissions rather than a single global role.

---

### 29.6 Pundit vs CanCanCan

| | **Pundit** | **CanCanCan** |
| --- | --- | --- |
| **DSL** | Plain Ruby classes (one per model) | Single `Ability` class with DSL |
| **Scoping** | Explicit `Scope` inner class | `accessible_by` on AR models |
| **Testing** | Unit test the policy class directly | Test via controller or unit |
| **Complexity** | Scales well — policies are isolated | Can become one huge `Ability` file |
| **GitLab uses** | Custom policy framework inspired by Pundit | — |
| **Recommended for** | Most new Rails apps | Legacy apps already using it |

GitLab has its own policy framework (`DeclarativePolicy`) built on the same
concept as Pundit but with explicit dependency graphs between rules, allowing
it to short-circuit expensive permission checks.

---

### 29.7 Authentication & Authorization — Interview Q&A

**Q: What is the difference between authentication and authorization?**

> Authentication verifies identity — "who are you?" It typically involves
> a credential (password, token) and produces a session or token that
> subsequent requests use. Authorization verifies permissions — "are you
> allowed to do this?" It takes the authenticated identity and checks it
> against a set of rules. They are separate layers: authenticate first,
> then authorize each action.

**Q: How does Devise work under the hood?**

> Devise is a Rails Engine composed of modules. `database_authenticatable`
> stores a `bcrypt`-hashed password in `encrypted_password`. On sign-in,
> it runs `BCrypt::Password.new(encrypted_password) == submitted_password`
> (constant-time comparison). On success it writes the user's ID into
> `session[:user_id]` (via Warden, which Devise sits on top of). Subsequent
> requests call `current_user` which does `User.find(session[:user_id])`.

**Q: Why does GitLab prefer DB-stored tokens over JWT for its API?**

> JWTs are self-contained and cannot be revoked before their expiry time
> without maintaining a blocklist — which defeats the statelessness
> advantage. If a personal access token is stolen, GitLab can delete the
> row and it is immediately invalid. JWTs require waiting for expiry or
> implementing a blocklist. For an API that handles production infrastructure,
> revocability is a hard requirement.

**Q: What does Pundit's `verify_authorized` after_action do?**

> It raises `Pundit::AuthorizationNotPerformedError` if the action
> completes without having called `authorize`. This is a safety net — any
> controller action that forgets to authorize will fail loudly rather than
> silently allowing access. It prevents accidentally unprotected endpoints
> from reaching production.

**Q: What is the difference between `authorize` and `policy_scope` in Pundit?**

> `authorize(record)` checks a single-record permission — "can this user
> perform this action on this specific issue?" It raises an error if denied.
> `policy_scope(relation)` filters a collection — "which of these issues
> can this user see?" It returns a scoped `ActiveRecord::Relation`. Use
> `authorize` in `show`, `update`, `destroy`; use `policy_scope` in `index`.

**Q: How would you implement per-project roles like GitLab?**

> Use a `memberships` join table with `user_id`, `project_id`, and an
> `access_level` integer enum. A user's role is scoped to each project
> independently. In Pundit policy scopes, filter by
> `user.memberships.where(access_level: developer_and_above)`. This is
> more flexible than a global role column because the same user can be a
> maintainer in one project and a guest in another.

---
