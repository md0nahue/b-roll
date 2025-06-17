require "test_helper"

class VideoCreationTest < ActiveSupport::TestCase
  setup do
    @user = users(:one)

    @fixtures_files_path = Rails.root.join("test", "fixtures", "files")
    FileUtils.mkdir_p(@fixtures_files_path)
    @sample_video_path = @fixtures_files_path.join("sample_video.mp4")

    unless File.exist?(@sample_video_path)
      File.open(@sample_video_path, "wb") { |f| f.write("0000ftypmp420000isommp42") }
    end
  end

  test "should be valid with a title, user, and attached file" do
    video_creation = @user.video_creations.build(title: "Test Video")
    video_creation.file.attach(io: File.open(@sample_video_path), filename: "sample_video.mp4", content_type: "video/mp4")
    assert video_creation.valid?, "VideoCreation should be valid but had errors: #{video_creation.errors.full_messages.to_sentence}"
  end

  test "should not be valid without a title" do
    video_creation = @user.video_creations.build
    # Attach a file to isolate the title validation
    video_creation.file.attach(io: File.open(@sample_video_path), filename: "sample_video.mp4", content_type: "video/mp4")
    assert_not video_creation.valid?
    assert_includes video_creation.errors[:title], "can't be blank"
  end

  test "should not be valid without a file (presence validation)" do
    video_creation = @user.video_creations.build(title: "Test Video No File")
    # Do not attach a file to test presence validation
    assert_not video_creation.valid?
    assert_includes video_creation.errors[:file], "can't be blank"
  end

  test "should belong to a user" do
    video_creation = @user.video_creations.build(title: "User Association Test")
    video_creation.file.attach(io: File.open(@sample_video_path), filename: "sample_video.mp4", content_type: "video/mp4")
    assert video_creation.valid?
    assert_equal @user, video_creation.user
  end
end
