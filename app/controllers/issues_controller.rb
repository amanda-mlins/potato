class IssuesController < ApplicationController
  before_action :set_project, only: %i[new create]
  before_action :set_issue, only: %i[show edit update destroy]

  def show
  end

  def new
    @issue = @project.issues.new
  end

  def create
    @issue = @project.issues.new(issue_params)

    if @issue.save
      redirect_to @issue, notice: "Issue was successfully created."
    else
      render :new, status: :unprocessable_entity
    end
  end

  def edit
  end

  def update
    if @issue.update(issue_params)
      redirect_to @issue, notice: "Issue was successfully updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    @issue.destroy!
    redirect_to project_issues_path(@issue.project), notice: "Issue was successfully deleted."
  end

  private

  def set_project
    @project = Project.find(params[:project_id])
  end

  def set_issue
    @issue = Issue.find(params[:id])
  end

  def issue_params
    params.require(:issue).permit(:title, :description, :status)
  end
end
