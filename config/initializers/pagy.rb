# frozen_string_literal: true

# Pagy initializer — https://ddnexus.github.io/pagy/docs/api/pagy/

# Default page size (overridable per-call with `limit:`)
Pagy::DEFAULT[:limit] = 25

# Include the backend helper in all controllers
require "pagy/extras/metadata" # adds pagy_metadata for JSON API responses
require "pagy/extras/overflow" # handle ?page=99999 gracefully — return last page
Pagy::DEFAULT[:overflow] = :last_page
