ActiveRecord::Base.logger = Logger.new(STDOUT)

puts "\n#{'=' * 60}"
puts "1. includes(:labels) — what SQL does it actually fire?"
puts "=" * 60
issues = Issue.includes(:labels).all.load
# Force load so we see the queries immediately

puts "\n#{'=' * 60}"
puts "2. includes — switches to LEFT OUTER JOIN when you filter"
puts "   on the associated table (where / order)"
puts "=" * 60
Issue.includes(:labels).where(labels: { name: "backend" }).load

puts "\n#{'=' * 60}"
puts "3. For the index page scenario you described:"
puts "   Project.includes(issues: :labels)"
puts "=" * 60
Project.includes(issues: :labels).load
