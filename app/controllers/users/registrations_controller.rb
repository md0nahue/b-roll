class Users::RegistrationsController < Devise::RegistrationsController
  protected

  def after_sign_up_path_for(resource)
    new_video_creation_path # Or your desired path
  end
end
