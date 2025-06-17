class VideoCreationsController < ApplicationController
  before_action :authenticate_user! # Ensure user is logged in

  def new
    @video_creation = current_user.video_creations.build
  end

  def create
    @video_creation = current_user.video_creations.build(video_creation_params)
    if @video_creation.save
      # Redirect to a success page, e.g., the user's dashboard or the video show page
      # For now, let's redirect to the root path with a success message
      redirect_to root_path, notice: 'Video was successfully uploaded.'
    else
      render :new, status: :unprocessable_entity
    end
  end

  private

  def video_creation_params
    params.require(:video_creation).permit(:title, :file)
  end
end
