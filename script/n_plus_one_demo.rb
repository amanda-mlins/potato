ActiveRecord::Base.logger = Logger.new(STDOUT)

puts "\n#{'=' * 50}"
puts "N+1 PROBLEM — watch how many queries fire"
puts "=" * 50

projects = Project.all
projects.each do |project|
  project.issues.each do |issue|
    issue.labels.map(&:name)
  end
end

puts "\n#{'=' * 50}"
puts "FIXED — with includes (eager loading)"
puts "=" * 50

projects = Project.includes(issues: :labels).all
projects.each do |project|
  project.issues.each do |issue|
    issue.labels.map(&:name)
  end
end
