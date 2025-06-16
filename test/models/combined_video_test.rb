require "test_helper"

class CombinedVideoTest < ActiveSupport::TestCase
  test "can be instantiated" do
    combined_video = CombinedVideo.new
    assert_instance_of CombinedVideo, combined_video
  end

  test "can save and retrieve attributes" do
    s3_url = "s3://my-bucket/my-video.mp4"
    status = "completed"
    error = "Something went wrong."

    combined_video = CombinedVideo.create!(
      s3_url: s3_url,
      status: status,
      error_message: error
    )

    retrieved_video = CombinedVideo.find(combined_video.id)
    assert_equal s3_url, retrieved_video.s3_url
    assert_equal status, retrieved_video.status
    assert_equal error, retrieved_video.error_message
  end

  test "status can be updated" do
    combined_video = CombinedVideo.create!(status: "processing")
    combined_video.update!(status: "completed")
    assert_equal "completed", combined_video.reload.status
  end

  # Example of how status validation could be tested if added:
  # test "should not allow invalid status" do
  #   combined_video = CombinedVideo.new(status: "invalid_status_value")
  #   assert_not combined_video.valid?
  #   assert_includes combined_video.errors[:status], "is not a valid status"
  # end
end
