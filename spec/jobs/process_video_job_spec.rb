require 'rails_helper'

RSpec.describe ProcessVideoJob, type: :job do
  include ActiveJob::TestHelper

  let(:combined_video) { create(:combined_video, status: 'pending') }
  let(:s3_client_double) { instance_double(Aws::S3::Client) }
  let(:ffmpeg_movie_double) { instance_double(FFMPEG::Movie) }
  let(:tmp_dir_path_regex) { %r{tmp/process_video_job_[a-zA-Z0-9\-_]+_cv_#{combined_video.id}} }

  let(:video_url1) { "s3://test-bucket/video1.mp4" }
  let(:video_url2) { "s3://test-bucket/video2.mp4" }
  let(:audio_url) { "s3://test-bucket/audio.mp3" }
  let(:s3_bucket_name) { "test-bucket-from-spec" }
  let(:aws_region) { "us-east-1" }

  let!(:config_double) { double('S3ConfigStub') }

  before do
    allow(Aws::S3::Client).to receive(:new).and_return(s3_client_double)
    allow(s3_client_double).to receive(:get_object).and_return(true)
    allow(s3_client_double).to receive(:put_object).and_return(true)

    allow(config_double).to receive(:region).and_return(aws_region)
    allow(config_double).to receive(:bucket).and_return(s3_bucket_name)
    allow(s3_client_double).to receive(:config).and_return(config_double)

    credentials_double = double('Credentials')
    allow(Rails.application).to receive(:credentials).and_return(credentials_double)
    allow(credentials_double).to receive(:dig).with(:aws, :s3_bucket_name).and_return(s3_bucket_name)
    allow(credentials_double).to receive(:dig).with(:aws, :access_key_id).and_return("test_access_key_id")
    allow(credentials_double).to receive(:dig).with(:aws, :secret_access_key).and_return("test_secret_access_key")
    allow(credentials_double).to receive(:dig).with(:aws, :region).and_return(aws_region)


    allow(FFMPEG::Movie).to receive(:new).and_return(ffmpeg_movie_double)
    allow(ffmpeg_movie_double).to receive(:transcode).and_return(true)

    # Default stub for backticks - individual tests may override
    allow_any_instance_of(ProcessVideoJob).to receive(:`).and_return("")

    allow(SecureRandom).to receive(:uuid).and_return("test-uuid")

    allow(Rails.logger).to receive(:info)
    allow(Rails.logger).to receive(:error)

    allow(File).to receive(:open).and_call_original
  end

  after do
    FileUtils.rm_rf(Dir.glob(Rails.root.join("tmp", "process_video_job_*_cv_#{combined_video.id}")))
    FileUtils.rm_rf(Dir.glob(Rails.root.join("tmp", "process_video_job_*_cv_-1")))
  end

  describe "#perform" do
    context "when CombinedVideo record does not exist" do
      it "logs an error and aborts" do
        expect(Rails.logger).to receive(:error).with("ProcessVideoJob: CombinedVideo record with ID -1 not found. Aborting.")
        expect { ProcessVideoJob.perform_now(-1, [video_url1]) }.not_to raise_error
      end
    end

    context "when video URLs are empty" do
      it "updates status to failed and logs error, then re-raises" do
        expect {
          ProcessVideoJob.perform_now(combined_video.id, [])
        }.to raise_error(RuntimeError, /No videos to process for CombinedVideo ID: #{combined_video.id}/)
        combined_video.reload
        expect(combined_video.status).to eq('failed')
        expect(combined_video.error_message).to include("No videos to process")
      end
    end

    context "successful processing scenarios" do
      def expect_s3_download(url, tmp_path_matcher)
        bucket, key = ProcessVideoJob.new.send(:parse_s3_url, url)
        expect(s3_client_double).to receive(:get_object).with(
          response_target: a_string_matching(tmp_path_matcher),
          bucket: bucket,
          key: key
        ).and_return(true)
      end

      def expect_s3_upload(expected_bucket_name_string, key_matcher)
         expect(s3_client_double).to receive(:put_object).with(
            hash_including(
              bucket: expected_bucket_name_string,
              key: a_string_matching(key_matcher),
              body: an_instance_of(StringIO),
              acl: 'private'
            )
        ).and_return(true)
      end

      it "updates status to processing initially" do
        allow_any_instance_of(ProcessVideoJob).to receive(:download_s3_file).and_return("mocked_path/video1.mp4")
        allow(FileUtils).to receive(:cp).and_return(true)

        expected_tmp_dir_str = Rails.root.join("tmp", "process_video_job_test-uuid_cv_#{combined_video.id}").to_s
        expected_output_file = File.join(expected_tmp_dir_str, "combined_video_test-uuid.mp4")
        allow(File).to receive(:open).with(eq(expected_output_file), 'rb').and_yield(StringIO.new("dummy video content"))

        ProcessVideoJob.perform_now(combined_video.id, [video_url1])
        reloaded_cv = CombinedVideo.find(combined_video.id)
        expect(reloaded_cv.status).to eq('completed')
      end

      context "with one video, no audio" do
        let(:expected_tmp_dir_str) { Rails.root.join("tmp", "process_video_job_test-uuid_cv_#{combined_video.id}").to_s }
        let(:expected_output_file) { File.join(expected_tmp_dir_str, "combined_video_test-uuid.mp4") }
        before do
          expect_s3_download(video_url1, /video_0_video1.mp4/)
          expect(FileUtils).to receive(:cp).with(a_string_matching(/video_0_video1.mp4/), eq(expected_output_file)).and_return(true)
          allow(File).to receive(:open).with(eq(expected_output_file), 'rb').and_yield(StringIO.new("dummy video content"))
          expect_s3_upload(s3_bucket_name, %r{processed_videos/cv_#{combined_video.id}/combined_video_test-uuid\.mp4})
        end

        it "copies the video, uploads to S3, and updates CombinedVideo" do
          ProcessVideoJob.perform_now(combined_video.id, [video_url1])
          combined_video.reload
          expect(combined_video.status).to eq('completed')
          expected_s3_url_regex = %r{https://#{Regexp.escape(s3_bucket_name)}\.s3\.#{Regexp.escape(aws_region)}\.amazonaws\.com/processed_videos/cv_#{combined_video.id}/combined_video_test-uuid\.mp4}
          expect(combined_video.s3_url).to match(expected_s3_url_regex)
          expect(combined_video.error_message).to be_nil
        end
      end

      context "with one video and audio" do
        let(:expected_tmp_dir_str) { Rails.root.join("tmp", "process_video_job_test-uuid_cv_#{combined_video.id}").to_s }
        let(:expected_output_file) { File.join(expected_tmp_dir_str, "combined_video_test-uuid.mp4") }
        before do
          expect_s3_download(video_url1, /video_0_video1.mp4/)
          expect_s3_download(audio_url, /audio_audio.mp3/)
          expect(ffmpeg_movie_double).to receive(:transcode).with(
            eq(expected_output_file),
            %W(-i #{File.join(expected_tmp_dir_str, "audio_audio.mp3")} -c:v copy -c:a aac -map 0:v:0 -map 1:a:0 -shortest)
          ).and_return(true)
          allow(File).to receive(:open).with(eq(expected_output_file), 'rb').and_yield(StringIO.new("dummy video content"))
          expect_s3_upload(s3_bucket_name, %r{processed_videos/cv_#{combined_video.id}/combined_video_test-uuid.mp4})
        end

        it "transcodes with audio, uploads, and updates CombinedVideo" do
          ProcessVideoJob.perform_now(combined_video.id, [video_url1], audio_url)
          combined_video.reload
          expect(combined_video.status).to eq('completed')
          expect(combined_video.s3_url).to include("combined_video_test-uuid.mp4")
        end
      end

      context "with multiple videos, no audio" do
        let(:expected_tmp_dir_str) { Rails.root.join("tmp", "process_video_job_test-uuid_cv_#{combined_video.id}").to_s }
        let(:expected_concat_list_path) { File.join(expected_tmp_dir_str, "concat_list.txt") }
        let(:expected_output_file) { File.join(expected_tmp_dir_str, "combined_video_test-uuid.mp4") }
        let(:expected_ffmpeg_command_start) { "ffmpeg -f concat -safe 0 -i #{expected_concat_list_path} -c copy #{expected_output_file}" }

        before do
          expect_s3_download(video_url1, /video_0_video1.mp4/)
          expect_s3_download(video_url2, /video_1_video2.mp4/)
          # Specific stub for this context to ensure $?.success? is true
          allow_any_instance_of(ProcessVideoJob).to receive(:`).with(a_string_starting_with(expected_ffmpeg_command_start)) do
            # Simulate a successful command by ensuring $? is not nil and success? is true
            system("true") # Executes a command that is guaranteed to succeed and set $?
            "ffmpeg output" # Return value of the backtick
          end
          allow(File).to receive(:open).with(eq(expected_output_file), 'rb').and_yield(StringIO.new("dummy video content"))
          expect_s3_upload(s3_bucket_name, %r{processed_videos/cv_#{combined_video.id}/combined_video_test-uuid.mp4})
        end

        it "concatenates videos, uploads, and updates CombinedVideo" do
          ProcessVideoJob.perform_now(combined_video.id, [video_url1, video_url2])
          combined_video.reload
          expect(combined_video.status).to eq('completed')
          expect(combined_video.s3_url).to include("combined_video_test-uuid.mp4")
        end
      end

      context "with multiple videos and audio" do
        let(:expected_tmp_dir_str) { Rails.root.join("tmp", "process_video_job_test-uuid_cv_#{combined_video.id}").to_s }
        let(:expected_concat_list_path) { File.join(expected_tmp_dir_str, "concat_list.txt") }
        let(:concat_output_path) { File.join(expected_tmp_dir_str, "combined_video_test-uuid.mp4") }
        let(:final_output_path) { File.join(expected_tmp_dir_str, "final_with_audio_test-uuid.mp4") }
        let(:expected_ffmpeg_command_start) { "ffmpeg -f concat -safe 0 -i #{expected_concat_list_path} -c copy #{concat_output_path}" }

        before do
          expect_s3_download(video_url1, /video_0_video1.mp4/)
          expect_s3_download(video_url2, /video_1_video2.mp4/)
          expect_s3_download(audio_url, /audio_audio.mp3/)

          allow_any_instance_of(ProcessVideoJob).to receive(:`).with(a_string_starting_with(expected_ffmpeg_command_start)) do
            system("true") # Ensure $? is set and success? is true
            "ffmpeg concat output"
          end

          concatenated_movie_double = instance_double(FFMPEG::Movie, path: concat_output_path)
          allow(FFMPEG::Movie).to receive(:new).with(eq(concat_output_path)).and_return(concatenated_movie_double)

          expect(concatenated_movie_double).to receive(:transcode).with(
            eq(final_output_path),
            %W(-i #{File.join(expected_tmp_dir_str, "audio_audio.mp3")} -c:v copy -c:a aac -map 0:v:0 -map 1:a:0 -shortest)
          ).and_return(true)

          allow(File).to receive(:open).with(eq(final_output_path), 'rb').and_yield(StringIO.new("dummy final content"))
          expect_s3_upload(s3_bucket_name, %r{processed_videos/cv_#{combined_video.id}/final_with_audio_test-uuid.mp4})
        end

        it "concatenates, adds audio, uploads, and updates CombinedVideo" do
          ProcessVideoJob.perform_now(combined_video.id, [video_url1, video_url2], audio_url)
          combined_video.reload
          expect(combined_video.status).to eq('completed')
          expect(combined_video.s3_url).to include("final_with_audio_test-uuid.mp4")
        end
      end

      it "cleans up the temporary directory on success" do
        allow(FileUtils).to receive(:cp).and_return(true)
        expected_tmp_dir_str = Rails.root.join("tmp", "process_video_job_test-uuid_cv_#{combined_video.id}").to_s
        expected_output_file = File.join(expected_tmp_dir_str, "combined_video_test-uuid.mp4")
        allow(File).to receive(:open).with(eq(expected_output_file), 'rb').and_yield(StringIO.new("dummy video content"))

        expected_tmp_pathname = Pathname(Rails.root.join("tmp", "process_video_job_test-uuid_cv_#{combined_video.id}"))
        expect(FileUtils).to receive(:remove_entry_secure).with(eq(expected_tmp_pathname), force: true)
        ProcessVideoJob.perform_now(combined_video.id, [video_url1])
      end
    end

    context "error handling scenarios" do
      def expect_cleanup_and_perform_with_error(expected_error_class = StandardError, message_regex = nil)
        expected_tmp_pathname = Pathname(Rails.root.join("tmp", "process_video_job_test-uuid_cv_#{combined_video.id}"))
        allow(File).to receive(:open).with(a_string_matching(/combined_video_test-uuid.mp4|final_with_audio_test-uuid.mp4/), "rb").and_yield(StringIO.new("dummy error content"))

        expect(FileUtils).to receive(:remove_entry_secure).with(eq(expected_tmp_pathname), force: true).at_least(:once)

        if message_regex
          expect { yield }.to raise_error(expected_error_class, message_regex)
        else
          expect { yield }.to raise_error(expected_error_class)
        end
      end

      it "handles S3 download failure" do
        allow(s3_client_double).to receive(:get_object).and_raise(Aws::S3::Errors::NoSuchKey.new(nil, "Test S3 error"))

        expect_cleanup_and_perform_with_error(RuntimeError, /File not found on S3: #{Regexp.escape(video_url1)}/) do
          ProcessVideoJob.perform_now(combined_video.id, [video_url1])
        end
        combined_video.reload
        expect(combined_video.status).to eq('failed')
        expect(combined_video.error_message).to include("File not found on S3: #{video_url1}")
      end

      it "handles FFMPEG concat failure" do
        allow_any_instance_of(ProcessVideoJob).to receive(:`).with(/ffmpeg -f concat/) do
          # Simulate the external command failing by setting $? appropriately
          system("false") # Executes a command that is guaranteed to fail
          "ffmpeg error output" # Return value of the backtick
        end

        expect_cleanup_and_perform_with_error(RuntimeError, /FFMPEG concat command failed/) do
          ProcessVideoJob.perform_now(combined_video.id, [video_url1, video_url2])
        end
        combined_video.reload
        expect(combined_video.status).to eq('failed')
        expect(combined_video.error_message).to include("FFMPEG concat command failed")
      end

      it "handles FFMPEG transcode failure (single video with audio)" do
        downloaded_video_path_in_job = File.join(Rails.root.join("tmp", "process_video_job_test-uuid_cv_#{combined_video.id}"), "video_0_video1.mp4")
        allow(FFMPEG::Movie).to receive(:new).with(eq(downloaded_video_path_in_job)).and_return(ffmpeg_movie_double)
        allow(ffmpeg_movie_double).to receive(:transcode).and_raise(FFMPEG::Error.new("Test FFMPEG transcode error"))

        expect_cleanup_and_perform_with_error(FFMPEG::Error, "Test FFMPEG transcode error") do
          ProcessVideoJob.perform_now(combined_video.id, [video_url1], audio_url)
        end
        combined_video.reload
        expect(combined_video.status).to eq('failed')
        expect(combined_video.error_message).to include("Test FFMPEG transcode error")
      end

      it "handles S3 upload failure" do
        expected_tmp_dir_str = Rails.root.join("tmp", "process_video_job_test-uuid_cv_#{combined_video.id}").to_s
        expected_output_file = File.join(expected_tmp_dir_str, "combined_video_test-uuid.mp4")
        allow(FileUtils).to receive(:cp).with(a_string_matching(/video_0_video1.mp4/), eq(expected_output_file)).and_return(true)
        allow(File).to receive(:open).with(eq(expected_output_file), 'rb').and_yield(StringIO.new("dummy video content"))
        allow(s3_client_double).to receive(:put_object).and_raise(Aws::S3::Errors::ServiceError.new(nil, "Test S3 upload error"))

        expect_cleanup_and_perform_with_error(Aws::S3::Errors::ServiceError, "Test S3 upload error") do
             ProcessVideoJob.perform_now(combined_video.id, [video_url1])
        end
        combined_video.reload
        expect(combined_video.status).to eq('failed')
        expect(combined_video.error_message).to include("Test S3 upload error")
      end

      it "cleans up the temporary directory on generic failure" do
        allow(s3_client_double).to receive(:get_object).and_raise(StandardError.new("Generic processing error"))
        expected_tmp_pathname = Pathname(Rails.root.join("tmp", "process_video_job_test-uuid_cv_#{combined_video.id}"))
        expect(FileUtils).to receive(:remove_entry_secure).with(eq(expected_tmp_pathname), force: true)
        expect {
          ProcessVideoJob.perform_now(combined_video.id, [video_url1])
        }.to raise_error(RuntimeError) do |error|
          expect(error.message).to include("Error downloading")
          expect(error.message).to include(video_url1)
          expect(error.message).to include("Generic processing error")
        end
      end
    end
  end

  describe "#parse_s3_url" do
    let(:job_instance) { ProcessVideoJob.new }

    it "parses s3://bucket/key format" do
      bucket, key = job_instance.send(:parse_s3_url, "s3://my-bucket-name/path/to/file.mp4")
      expect(bucket).to eq("my-bucket-name")
      expect(key).to eq("path/to/file.mp4")
    end

    it "parses https://bucket.s3.region.amazonaws.com/key format" do
      bucket, key = job_instance.send(:parse_s3_url, "https://my-bucket.s3.us-east-1.amazonaws.com/another/path/video.mov")
      expect(bucket).to eq("my-bucket")
      expect(key).to eq("another/path/video.mov")
    end

    it "parses https://s3.region.amazonaws.com/bucket/key format" do
      bucket, key = job_instance.send(:parse_s3_url, "https://s3.eu-west-2.amazonaws.com/yet-another-bucket/and/a/key.webm")
      expect(bucket).to eq("yet-another-bucket")
      expect(key).to eq("and/a/key.webm")
    end

    it "parses https://bucket.s3-region.amazonaws.com/key format (alternative region format)" do
        bucket, key = job_instance.send(:parse_s3_url, "https://my-bucket.s3-ap-southeast-2.amazonaws.com/video/file.mp4")
        expect(bucket).to eq("my-bucket")
        expect(key).to eq("video/file.mp4")
    end

    it "returns [nil, nil] for invalid S3 URLs" do
      expect(job_instance.send(:parse_s3_url, "http://example.com/file.mp4")).to eq([nil, nil])
      expect(job_instance.send(:parse_s3_url, "ftp://my-bucket/some/key")).to eq([nil, nil])
      expect(job_instance.send(:parse_s3_url, "s3:/my-bucket/some/key")).to eq([nil, nil])
    end
  end
end
