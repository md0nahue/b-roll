require "test_helper"

class VideoCreationsControllerTest < ActionDispatch::IntegrationTest
  include Devise::Test::IntegrationHelpers # Include Devise test helpers

  setup do
    @user = users(:one) # From fixtures
    sign_in @user
    @sample_video_path = Rails.root.join("test", "fixtures", "files", "sample_video.mp4")
  end

  test "should get new" do
    get new_video_creation_path
    assert_response :success
  end

  test "should create video_creation" do
    assert_difference('VideoCreation.count') do
      post video_creations_path, params: {
        video_creation: {
          title: "Test Upload from Controller Test",
          file: fixture_file_upload(@sample_video_path, 'video/mp4')
        }
      }
    end
    assert_redirected_to root_path
    assert_equal 'Video was successfully uploaded.', flash[:notice]
  end
end
