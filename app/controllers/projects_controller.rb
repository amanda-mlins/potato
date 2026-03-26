class ProjectsController < ApplicationController
  before_action :set_project, only: %i[show edit update destroy]

  def index
    @projects = Project.order(created_at: :desc)

    respond_to do |format|
      format.html
      format.json # → app/views/projects/index.json.jbuilder
    end
  end

  def show
    @issues = @project.issues.recent.with_labels

    respond_to do |format|
      format.html
      format.json # → app/views/projects/show.json.jbuilder
    end
  end

  def new
    @project = Project.new
  end

  def create
    @project = Project.new(project_params)

    respond_to do |format|
      if @project.save
        format.html { redirect_to @project, notice: "Project was successfully created." }
        format.json { render json: @project, status: :created, location: @project }
      else
        format.html { render :new, status: :unprocessable_content }
        format.json { render json: @project.errors, status: :unprocessable_content }
      end
    end
  end

  def edit
  end

  def update
    respond_to do |format|
      if @project.update(project_params)
        format.html { redirect_to @project, notice: "Project was successfully updated." }
        format.json { render json: @project }
      else
        format.html { render :edit, status: :unprocessable_content }
        format.json { render json: @project.errors, status: :unprocessable_content }
      end
    end
  end

  def destroy
    @project.destroy!

    respond_to do |format|
      format.html { redirect_to projects_path, notice: "Project was successfully deleted." }
      format.json { head :no_content }
    end
  end

  private

  def set_project
    @project = Project.find(params[:id])
  end

  def project_params
    params.require(:project).permit(:name, :description)
  end
end
