class ApplicationController < ActionController::Base
  protected

  def after_sign_in_path_for(resource)
    root_path # or your_desired_path
  end
end
