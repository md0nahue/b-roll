require "test_helper"
require 'aws-sdk-s3' # Required for stubbing
require 'streamio-ffmpeg' # Required for stubbing

class ProcessVideoJobTest < ActiveJob::TestCase
  setup do
    @combined_video = CombinedVideo.create!(status: 'pending')
    @video_urls = ["s3://test-bucket/video1.mp4", "s3://test-bucket/video2.mp4"]
    @audio_url = "s3://test-bucket/audio.mp3"
    @job_id_for_tmp_path = "test_job_id" # To make tmp path predictable for mocking FileUtils

    # Mock S3 Client
    @mock_s3_client = Minitest::Mock.new
    Aws::S3::Client.stubs(:new).returns(@mock_s3_client)

    # Mock FileUtils
    FileUtils.stubs(:mkdir_p)
    FileUtils.stubs(:remove_entry_secure) # Changed from rm_rf to remove_entry_secure
    FileUtils.stubs(:cp) # For single video, no audio case

    # Mock File.open for concat list (general stub, can be more specific if needed)
    @mock_file = Minitest::Mock.new
    # File.stubs(:open).with(any_parameters).yields(@mock_file) # Basic stub
    # More specific stub for concat list:
    File.stubs(:open).with(includes("concat_list.txt"), "w").yields(@mock_file)
    @mock_file.stubs(:puts) # For writing "file '...'" to concat_list.txt

    # Mock streamio-ffmpeg Movie object
    @mock_ffmpeg_movie = Minitest::Mock.new
    FFMPEG::Movie.stubs(:new).returns(@mock_ffmpeg_movie)
    # Common stubs for @mock_ffmpeg_movie if methods like width, height, etc., are called by the job
    # For now, only transcode is directly used with specific options.
    # @mock_ffmpeg_movie.stubs(:transcode) # This will be set per test for specific args

    # Stub ProcessVideoJob's job_id to make temp path predictable
    ProcessVideoJob.any_instance.stubs(:job_id).returns(@job_id_for_tmp_path)

    # Default S3 bucket for uploads (from credentials or Active Storage config)
    # For testing, let's assume a bucket name from credentials
    Rails.application.credentials.stubs(:dig).with(:aws, :s3_bucket_name).returns("test-upload-bucket")
    Rails.application.credentials.stubs(:dig).with(:aws, :access_key_id).returns("test_access_key")
    Rails.application.credentials.stubs(:dig).with(:aws, :secret_access_key).returns("test_secret_key")
    Rails.application.credentials.stubs(:dig).with(:aws, :region).returns("us-east-1")

    # Ensure tmp directory for job is based on predictable job_id
    @expected_tmp_dir = Rails.root.join("tmp", "process_video_job_#{@job_id_for_tmp_path}_cv_#{@combined_video.id}")
  end

  def expect_s3_download(s3_client_mock, bucket, key, tmp_path_base)
    # Matcher for the path where the file will be downloaded
    path_matcher = ->(p) { p.start_with?(tmp_path_base.to_s) && p.end_with?(File.basename(key)) }
    s3_client_mock.expect(:get_object, nil, [{ response_target: path_matcher, bucket: bucket, key: key }])
  end

  test "successful job with multiple videos and no audio" do
    # Mock S3 downloads for videos
    expect_s3_download(@mock_s3_client, "test-bucket", "video1.mp4", @expected_tmp_dir)
    expect_s3_download(@mock_s3_client, "test-bucket", "video2.mp4", @expected_tmp_dir)

    # Mock ffmpeg concatenation (system call)
    ProcessVideoJob.any_instance.stubs(:`).with(includes("ffmpeg -f concat")).returns("ffmpeg output")
    ProcessVideoJob.any_instance.stubs(:$?).returns(stub(success?: true))

    # Mock S3 upload
    @mock_s3_client.expect(:put_object, nil, [Hash]) # Allow any hash for params for simplicity

    perform_enqueued_jobs do
      ProcessVideoJob.perform_later(@combined_video.id, @video_urls, nil)
    end

    @combined_video.reload
    assert_equal "completed", @combined_video.status
    assert_not_nil @combined_video.s3_url
    assert_match %r{https://test-upload-bucket.s3.us-east-1.amazonaws.com/processed_videos/cv_#{@combined_video.id}/combined_video_.*\.mp4}, @combined_video.s3_url
    assert_nil @combined_video.error_message

    @mock_s3_client.verify
  end

  test "successful job with multiple videos and audio" do
    expect_s3_download(@mock_s3_client, "test-bucket", "video1.mp4", @expected_tmp_dir)
    expect_s3_download(@mock_s3_client, "test-bucket", "video2.mp4", @expected_tmp_dir)
    expect_s3_download(@mock_s3_client, "test-bucket", "audio.mp3", @expected_tmp_dir)

    # Mock ffmpeg concatenation (system call)
    ProcessVideoJob.any_instance.stubs(:`).with(includes("ffmpeg -f concat")).returns("ffmpeg output")
    ProcessVideoJob.any_instance.stubs(:$?).returns(stub(success?: true))

    # Mock ffmpeg transcode for adding audio (called on FFMPEG::Movie instance)
    # This mock needs to be more specific if multiple transcode calls happen with different args
    @mock_ffmpeg_movie.expects(:transcode).with(includes("final_with_audio"), any_of(all_of(is_a(Array), includes("-map 0:v:0")),is_a(String))).once


    @mock_s3_client.expect(:put_object, nil, [Hash])

    perform_enqueued_jobs do
      ProcessVideoJob.perform_later(@combined_video.id, @video_urls, @audio_url)
    end

    @combined_video.reload
    assert_equal "completed", @combined_video.status
    assert_match %r{https://test-upload-bucket.s3.us-east-1.amazonaws.com/processed_videos/cv_#{@combined_video.id}/final_with_audio_.*\.mp4}, @combined_video.s3_url
    assert_nil @combined_video.error_message

    @mock_s3_client.verify
    @mock_ffmpeg_movie.verify # Verify transcode was called
  end

  test "job fails on S3 download error" do
    @mock_s3_client.expect(:get_object, nil, [Hash]) { raise Aws::S3::Errors::NoSuchKey.new("params", "message") }

    perform_enqueued_jobs do
      assert_raises(Aws::S3::Errors::NoSuchKey) do
        ProcessVideoJob.perform_later(@combined_video.id, @video_urls, nil)
      end
    end

    @combined_video.reload
    assert_equal "failed", @combined_video.status
    assert_not_nil @combined_video.error_message
    assert_match "File not found on S3: s3://test-bucket/video1.mp4", @combined_video.error_message

    @mock_s3_client.verify
  end

  test "job fails on ffmpeg concat error" do
    expect_s3_download(@mock_s3_client, "test-bucket", "video1.mp4", @expected_tmp_dir)
    expect_s3_download(@mock_s3_client, "test-bucket", "video2.mp4", @expected_tmp_dir)

    # Mock ffmpeg concatenation to fail
    ProcessVideoJob.any_instance.stubs(:`).with(includes("ffmpeg -f concat")).returns("ffmpeg error output")
    ProcessVideoJob.any_instance.stubs(:$?).returns(stub(success?: false)) # Simulate failure

    perform_enqueued_jobs do
      assert_raises(RuntimeError) do # Job re-raises the error
        ProcessVideoJob.perform_later(@combined_video.id, @video_urls, nil)
      end
    end

    @combined_video.reload
    assert_equal "failed", @combined_video.status
    assert_not_nil @combined_video.error_message
    assert_match "FFMPEG concat command failed. Output: ffmpeg error output", @combined_video.error_message

    @mock_s3_client.verify
  end

  test "job fails on ffmpeg transcode error (e.g. adding audio)" do
    expect_s3_download(@mock_s3_client, "test-bucket", "video1.mp4", @expected_tmp_dir)
    # For simplicity, testing single video + audio transcode failure
    single_video_url = ["s3://test-bucket/video1.mp4"]

    expect_s3_download(@mock_s3_client, "test-bucket", "audio.mp3", @expected_tmp_dir)

    # Mock FFMPEG::Movie#transcode to raise an error
    @mock_ffmpeg_movie.expects(:transcode).raises(FFMPEG::Error, "ffmpeg transcode failed")

    perform_enqueued_jobs do
      assert_raises(FFMPEG::Error) do
        ProcessVideoJob.perform_later(@combined_video.id, single_video_url, @audio_url)
      end
    end

    @combined_video.reload
    assert_equal "failed", @combined_video.status
    assert_not_nil @combined_video.error_message
    assert_equal "ffmpeg transcode failed", @combined_video.error_message

    @mock_s3_client.verify
    @mock_ffmpeg_movie.verify
  end

  test "job fails on S3 upload error" do
    expect_s3_download(@mock_s3_client, "test-bucket", "video1.mp4", @expected_tmp_dir)
    expect_s3_download(@mock_s3_client, "test-bucket", "video2.mp4", @expected_tmp_dir)

    ProcessVideoJob.any_instance.stubs(:`).with(includes("ffmpeg -f concat")).returns("ffmpeg output")
    ProcessVideoJob.any_instance.stubs(:$?).returns(stub(success?: true))

    # Mock S3 upload to fail
    @mock_s3_client.expect(:put_object, nil, [Hash]) { raise Aws::S3::Errors::AccessDenied.new("params", "message") }

    perform_enqueued_jobs do
      assert_raises(Aws::S3::Errors::AccessDenied) do
        ProcessVideoJob.perform_later(@combined_video.id, @video_urls, nil)
      end
    end

    @combined_video.reload
    assert_equal "failed", @combined_video.status
    assert_not_nil @combined_video.error_message
    assert_equal "message", @combined_video.error_message # S3 error messages are usually just the 'message' part
                                                          # May need adjustment based on how error is wrapped/logged.

    @mock_s3_client.verify
  end

  test "job with single video and no audio" do
    single_video_url_array = ["s3://test-bucket/video1.mp4"]
    expect_s3_download(@mock_s3_client, "test-bucket", "video1.mp4", @expected_tmp_dir)

    # FileUtils.cp is stubbed globally, no specific expectation needed unless verifying args

    @mock_s3_client.expect(:put_object, nil, [Hash])

    perform_enqueued_jobs do
      ProcessVideoJob.perform_later(@combined_video.id, single_video_url_array, nil)
    end

    @combined_video.reload
    assert_equal "completed", @combined_video.status
    assert_match %r{https://test-upload-bucket.s3.us-east-1.amazonaws.com/processed_videos/cv_#{@combined_video.id}/combined_video_.*\.mp4}, @combined_video.s3_url
    assert_nil @combined_video.error_message

    @mock_s3_client.verify
  end

  # Helper to match any hash arguments for mocks like put_object
  def any_hash
    ->(arg) { arg.is_a?(Hash) }
  end
end
