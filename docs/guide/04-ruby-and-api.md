# Rails Interview Guide — Part 4: Ruby & the JSON API Layer

> Sections 22–24: Ruby Particularities, Multi-Format Responses, Jbuilder

[← Back to index](README.md)

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

