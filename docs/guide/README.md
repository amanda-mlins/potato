# Rails Interview Guide

## Built while developing a GitLab-style Issue Tracker

> A living document of Rails concepts covered during mentorship sessions.
> Split into thematic files for easier navigation.

---

## Files

### [Part 1 — Rails Fundamentals](01-rails-fundamentals.md)

Sections 1–12 · ~870 lines

| # | Topic |
| --- | --- |
| 1 | Project Setup & PostgreSQL |
| 2 | Database Migrations |
| 3 | ActiveRecord Models & Associations |
| 4 | Validations |
| 5 | Enums |
| 6 | Creating & Updating Records |
| 7 | Zeitwerk — The Rails Autoloader |
| 8 | Routing & Nested Resources |
| 9 | Controllers |
| 10 | Views, Partials & Form Helpers |
| 11 | String Helpers — humanize, pluralize & Inflector |
| 12 | Initializers |

---

### [Part 2 — Database & SQL](02-database-and-sql.md)

Sections 13–20 · ~1,350 lines

| # | Topic |
| --- | --- |
| 13 | Scopes |
| 14 | N+1 Queries & Eager Loading |
| 15 | SQL Joins |
| 16 | Zero-Downtime Migrations |
| 17 | DDL Transactions & Index Algorithms |
| 18 | PostgreSQL Deep Dive |
| 19 | Foreign Keys, Database Locks & Constraint Patterns |
| 20 | Migration Methods — `change` vs `up`/`down` |

---

### [Part 3 — Testing](03-testing.md)

Sections 21, 27–28 · ~1,380 lines

| # | Topic |
| --- | --- |
| 21 | Testing with RSpec — The GitLab Way |
| 27 | Capybara & System Tests — Drivers, DSL, and Best Practices |
| 28 | The Testing Pyramid — Types of Tests in Rails & How GitLab Does It |

---

### [Part 4 — Ruby & the JSON API Layer](04-ruby-and-api.md)

Sections 22–24 · ~825 lines

| # | Topic |
| --- | --- |
| 22 | Ruby Particularities — Truthiness, Identity & Gotchas |
| 23 | Multi-Format Responses — `respond_to` and the JSON API Pattern |
| 24 | Jbuilder — JSON View Templates |

---

### [Part 5 — Architecture & Background Jobs](05-architecture.md)

Sections 25–26 · ~935 lines

| # | Topic |
| --- | --- |
| 25 | Where Logic Lives — Model, Controller, Service Object & Beyond |
| 26 | Background Jobs — ActiveJob & Solid Queue |

---

## Quick topic index

| Topic | File |
| --- | --- |
| ActiveRecord associations | [Part 1](01-rails-fundamentals.md) |
| ActiveRecord validations | [Part 1](01-rails-fundamentals.md) |
| Enums | [Part 1](01-rails-fundamentals.md) |
| Routing & nested resources | [Part 1](01-rails-fundamentals.md) |
| Controllers & `respond_to` | [Part 1](01-rails-fundamentals.md), [Part 4](04-ruby-and-api.md) |
| Scopes | [Part 2](02-database-and-sql.md) |
| N+1 queries & eager loading | [Part 2](02-database-and-sql.md) |
| SQL joins (`includes` / `joins`) | [Part 2](02-database-and-sql.md) |
| Zero-downtime migrations | [Part 2](02-database-and-sql.md) |
| PostgreSQL — indexes, JSONB, CTEs | [Part 2](02-database-and-sql.md) |
| Database locks & foreign keys | [Part 2](02-database-and-sql.md) |
| RSpec setup & GitLab testing style | [Part 3](03-testing.md) |
| FactoryBot & shared examples | [Part 3](03-testing.md) |
| Capybara drivers (rack_test, Selenium, Cuprite) | [Part 3](03-testing.md) |
| System tests & database cleaner | [Part 3](03-testing.md) |
| Testing pyramid & spec types | [Part 3](03-testing.md) |
| Ruby truthiness, identity, gotchas | [Part 4](04-ruby-and-api.md) |
| JSON API with Jbuilder | [Part 4](04-ruby-and-api.md) |
| Fat model vs service objects | [Part 5](05-architecture.md) |
| GitLab bounded contexts | [Part 5](05-architecture.md) |
| ActiveJob & Solid Queue | [Part 5](05-architecture.md) |
| Sidekiq / background workers | [Part 5](05-architecture.md) |
