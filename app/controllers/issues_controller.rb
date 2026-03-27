class IssuesController < ApplicationController
  before_action :set_project, only: %i[index new create]
  before_action :set_issue, only: %i[show edit update destroy]

  def index
    @pagy, @issues = pagy(@project.issues.with_labels.recent, limit: 25)

    respond_to do |format|
      format.html
      format.json # → app/views/issues/index.json.jbuilder
    end
  end

  def show
    respond_to do |format|
      format.html
      format.json # → app/views/issues/show.json.jbuilder
    end
  end

  def new
    @issue = @project.issues.new
  end

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

  def edit
  end

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

  def destroy
    @issue.destroy!

    respond_to do |format|
      format.html { redirect_to project_issues_path(@issue.project), notice: "Issue was successfully deleted." }
      format.json { head :no_content }
    end
  end

  private

  def set_project
    @project = Project.find(params[:project_id])
  end

  def set_issue
    @issue = Issue.find(params[:id])
  end

  def issue_params
    params.require(:issue).permit(:title, :description, :status, :author_name)
  end
end
