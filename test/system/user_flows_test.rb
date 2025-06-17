require "application_system_test_case"

class UserFlowsTest < ApplicationSystemTestCase
  setup do
    # Make sure Active Storage is using the test service
    ActiveStorage::Blob.service = :test
    # Create a dummy video file for uploads
    @sample_video_path = Rails.root.join("test", "fixtures", "files", "sample_video.mp4")
    # Ensure the dummy file exists (it was created in a previous step)
    # FileUtils.mkdir_p(Rails.root.join("test", "fixtures", "files"))
    # FileUtils.touch(@sample_video_path) # Or copy a real small video file there
  end

  test "user registration and video upload" do
    # Registration
    visit new_user_registration_path
    fill_in "Email", with: "newuser@example.com"
    fill_in "Password", with: "password123"
    fill_in "Password confirmation", with: "password123"
    click_on "Sign up"

    # Should be redirected to the video upload page
    assert_selector "h1", text: "Upload New Video"
    assert_current_path new_video_creation_path

    # Fill in video details and upload
    fill_in "Title", with: "My Awesome Video"
    attach_file "File", @sample_video_path
    click_on "Upload Video"

    # Should be redirected to the root path with a success notice
    assert_current_path root_path
    assert_text "Video was successfully uploaded."

    # Verify VideoCreation record
    user = User.find_by(email: "newuser@example.com")
    assert user.present?
    video_creation = user.video_creations.last
    assert video_creation.present?
    assert_equal "My Awesome Video", video_creation.title
    assert video_creation.file.attached?
    assert_equal "sample_video.mp4", video_creation.file.filename.to_s
  end
end
