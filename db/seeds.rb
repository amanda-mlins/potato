# This file should ensure the existence of records required to run the application in every environment (production,
# development, test). The code here should be idempotent so that it can be executed at any point in every environment.
# The data can then be loaded with the bin/rails db:seed command (or created alongside the database with db:setup).
#
# Example:
#
#   ["Action", "Comedy", "Drama", "Horror"].each do |genre_name|
#     MovieGenre.find_or_create_by!(name: genre_name)
#   end

[ "Project Alpha", "Project Beta", "Project Gamma" ].each do |project_name|
  project = Project.find_or_create_by!(name: project_name) do |project|
    project.description = "Description for #{project_name}"
  end

  5.times do |i|
    project.issues.find_or_create_by!(title: "Issue #{i + 1} for #{project_name}") do |issue|
      issue.description = "Description for Issue #{i + 1} in #{project_name}"
      issue.status = :open
      num_labels = rand(1..3)
      num_labels.times do |j|
        label = Label.find_or_create_by!(name: "Label #{j + 1} for #{project_name}", color: "##{SecureRandom.hex(3)}")
        issue.labels << label unless issue.labels.include?(label)
      end
    end
  end
end
