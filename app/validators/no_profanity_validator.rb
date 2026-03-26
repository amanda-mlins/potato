# frozen_string_literal: true

class NoProfanityValidator < ActiveModel::EachValidator
  DEFAULT_BLACKLIST = %w[foo bar baz]

  def initialize(options)
    super
    # allow callers to pass custom words via `validates :attr, no_profanity: { words: [...] }`
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
