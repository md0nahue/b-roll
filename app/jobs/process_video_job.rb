require 'aws-sdk-s3'
require 'streamio-ffmpeg'
require 'fileutils'
require 'open-uri'

class ProcessVideoJob < ApplicationJob
  queue_as :default

  def perform(combined_video_id, video_urls, audio_url = nil) # combined_video_id is now the first arg
    Rails.logger.info "ProcessVideoJob started for CombinedVideo ID: #{combined_video_id}, video_urls: #{video_urls.inspect}, audio_url: #{audio_url.inspect}"

    combined_video = CombinedVideo.find_by(id: combined_video_id)
    unless combined_video
      Rails.logger.error "ProcessVideoJob: CombinedVideo record with ID #{combined_video_id} not found. Aborting."
      return # Or raise an error
    end

    combined_video.update(status: 'processing', error_message: nil) # Clear previous errors

    tmp_dir = Rails.root.join("tmp", "process_video_job_#{self.job_id}_cv_#{combined_video_id}")
    FileUtils.mkdir_p(tmp_dir)

    downloaded_video_paths = []
    downloaded_audio_path = nil
    processed_s3_url = nil # Renamed from combined_video_s3_url to avoid confusion with model field

    begin
      s3_client = Aws::S3::Client.new(
        access_key_id: Rails.application.credentials.dig(:aws, :access_key_id),
        secret_access_key: Rails.application.credentials.dig(:aws, :secret_access_key),
        region: Rails.application.credentials.dig(:aws, :region)
      )

      Rails.logger.info "Downloading videos for CombinedVideo ID: #{combined_video_id}..."
      video_urls.each_with_index do |video_url, index|
        filename = File.join(tmp_dir, "video_#{index}_#{File.basename(URI.parse(video_url).path)}")
        download_s3_file(s3_client, video_url, filename)
        downloaded_video_paths << filename
        Rails.logger.info "Downloaded #{video_url} to #{filename} for CV ID: #{combined_video_id}"
      end

      if audio_url.present?
        Rails.logger.info "Downloading audio for CombinedVideo ID: #{combined_video_id}..."
        audio_filename = File.join(tmp_dir, "audio_#{File.basename(URI.parse(audio_url).path)}")
        download_s3_file(s3_client, audio_url, audio_filename)
        downloaded_audio_path = audio_filename
        Rails.logger.info "Downloaded #{audio_url} to #{downloaded_audio_path} for CV ID: #{combined_video_id}"
      end

      Rails.logger.info "Combining videos for CombinedVideo ID: #{combined_video_id}..."
      output_filename = File.join(tmp_dir, "combined_video_#{SecureRandom.uuid}.mp4")

      if downloaded_video_paths.empty?
        raise "No videos to process for CombinedVideo ID: #{combined_video_id}."
      end

      ffmpeg_videos = downloaded_video_paths.map { |path| FFMPEG::Movie.new(path) }

      if ffmpeg_videos.length == 1 && downloaded_audio_path.blank?
        FileUtils.cp(downloaded_video_paths.first, output_filename)
        Rails.logger.info "Only one video provided, using original as output for CV ID: #{combined_video_id}."
      elsif ffmpeg_videos.length == 1 && downloaded_audio_path.present?
        main_video = ffmpeg_videos.first
        # audio_track = FFMPEG::Movie.new(downloaded_audio_path) # Not actually used by transcode like this
        main_video.transcode(output_filename, %W(-i #{downloaded_audio_path} -c:v copy -c:a aac -map 0:v:0 -map 1:a:0 -shortest))
        Rails.logger.info "Combined one video with new audio track for CV ID: #{combined_video_id}."
      else
        file_list_path = File.join(tmp_dir, "concat_list.txt")
        File.open(file_list_path, 'w') do |file|
          downloaded_video_paths.each do |vid_path|
            file.puts "file '#{vid_path}'" # Ensure paths are correctly quoted for ffmpeg
          end
        end

        ffmpeg_command = ["ffmpeg", "-f", "concat", "-safe", "0", "-i", file_list_path, "-c", "copy", output_filename]
        Rails.logger.info "Executing ffmpeg concat command for CV ID #{combined_video_id}: #{ffmpeg_command.join(' ')}"

        # Capture ffmpeg output for debugging if needed
        ffmpeg_output = `#{ffmpeg_command.join(' ')} 2>&1` # Using backticks for output capture
        unless $?.success?
          Rails.logger.error "FFMPEG concat command failed for CV ID #{combined_video_id}. Output: #{ffmpeg_output}"
          raise "FFMPEG concat command failed. Output: #{ffmpeg_output}"
        end
        Rails.logger.info "Successfully concatenated videos for CV ID: #{combined_video_id}."

        if downloaded_audio_path.present?
          Rails.logger.info "Adding audio track to concatenated video for CV ID: #{combined_video_id}..."
          concatenated_video_with_audio_filename = File.join(tmp_dir, "final_with_audio_#{SecureRandom.uuid}.mp4")
          current_video_movie = FFMPEG::Movie.new(output_filename)

          current_video_movie.transcode(concatenated_video_with_audio_filename, %W(-i #{downloaded_audio_path} -c:v copy -c:a aac -map 0:v:0 -map 1:a:0 -shortest))
          output_filename = concatenated_video_with_audio_filename
          Rails.logger.info "Successfully added audio to concatenated video for CV ID: #{combined_video_id}."
        end
      end
      Rails.logger.info "Video processing complete for CV ID: #{combined_video_id}. Output at: #{output_filename}"

      Rails.logger.info "Uploading processed video to S3 for CV ID: #{combined_video_id}..."
      s3_upload_bucket = Rails.application.credentials.dig(:aws, :s3_bucket_name) || Rails.application.config.active_storage.service_configurations.dig(:amazon, :bucket)
      raise "S3 bucket for upload is not configured." unless s3_upload_bucket

      s3_upload_key = "processed_videos/cv_#{combined_video_id}/#{File.basename(output_filename)}" # Add CV ID to path

      File.open(output_filename, 'rb') do |file|
        s3_client.put_object(
          bucket: s3_upload_bucket,
          key: s3_upload_key,
          body: file,
          acl: 'private'
        )
      end

      region = s3_client.config.region
      processed_s3_url = "https://#{s3_upload_bucket}.s3.#{region}.amazonaws.com/#{s3_upload_key}"
      Rails.logger.info "Successfully uploaded processed video for CV ID #{combined_video_id} to S3: #{processed_s3_url}"

      # Update CombinedVideo record with S3 URL and status 'completed'
      combined_video.update!(
        s3_url: processed_s3_url,
        status: 'completed',
        error_message: nil
      )
      Rails.logger.info "ProcessVideoJob successfully completed for CombinedVideo ID: #{combined_video_id}."

    rescue StandardError => e
      Rails.logger.error "ProcessVideoJob failed for CombinedVideo ID: #{combined_video_id}. Error: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      if combined_video # Check if record was found before trying to update
        combined_video.update(status: 'failed', error_message: e.message)
      end
      # Do not re-raise if job runner handles this based on no error (depends on runner config)
      # For now, re-raising to ensure it's marked as a failed job by default job runners like Sidekiq.
      raise e
    ensure
      Rails.logger.info "Cleaning up temporary directory: #{tmp_dir} for CV ID: #{combined_video_id}"
      FileUtils.remove_entry_secure(tmp_dir, force: true) if Dir.exist?(tmp_dir)
      Rails.logger.info "ProcessVideoJob finished for CombinedVideo ID: #{combined_video_id}."
    end
  end

  private

  def download_s3_file(s3_client, s3_url_str, local_path)
    bucket_name, key = parse_s3_url(s3_url_str)
    unless bucket_name && key
      raise "Invalid S3 URL format: #{s3_url_str}."
    end

    Rails.logger.info "Attempting to download s3://#{bucket_name}/#{key} to #{local_path}"
    s3_client.get_object(response_target: local_path, bucket: bucket_name, key: key)
  rescue Aws::S3::Errors::NoSuchKey
    Rails.logger.error "File not found on S3: s3://#{bucket_name}/#{key}"
    raise "File not found on S3: #{s3_url_str}"
  rescue StandardError => e # Catch other S3 errors
    Rails.logger.error "Error downloading from S3 (s3://#{bucket_name}/#{key}): #{e.message}"
    raise "Error downloading #{s3_url_str}: #{e.message}" # Re-raise with specific file
  end

  def parse_s3_url(url_str)
    uri = URI.parse(url_str)
    key = uri.path.gsub(%r{^/}, '') # Key is usually the path, minus leading slash

    if uri.scheme == 's3'
      return [nil, nil] if uri.host.blank? # Invalid if host (bucket) is missing for s3 scheme
      return [uri.host, key]
    elsif uri.scheme == 'https' && uri.host.end_with?('amazonaws.com')
      host_parts = uri.host.split('.')

      # Case 1: bucket.s3.region.amazonaws.com OR bucket.s3-region.amazonaws.com
      # e.g. my-bucket.s3.us-east-1.amazonaws.com or my-bucket.s3-us-east-1.amazonaws.com
      # or my-bucket.s3.amazonaws.com (older global virtual hosted)
      if host_parts.length > 3 && host_parts[1..-1].join('.').start_with?('s3')
        # Bucket is the first part of the hostname (e.g., "my-bucket" from "my-bucket.s3...")
        # This also handles bucket names with dots like "my.cool.bucket"
        # by finding the ".s3" part and taking everything before it.
        s3_domain_index = host_parts.find_index { |part| part.match?(/^s3(?:[-.][a-zA-Z0-9-]+)?$/) || part == "s3" }

        if s3_domain_index && s3_domain_index > 0
          bucket = host_parts[0...s3_domain_index].join('.')
          # Key is already derived from uri.path
          return [bucket, key]
        end
      end

      # Case 2: s3.region.amazonaws.com/bucket/key OR s3-region.amazonaws.com/bucket/key
      # e.g. s3.us-east-1.amazonaws.com/my-bucket/path/to/file
      # OR s3.amazonaws.com/my-bucket/path/to/file (older global path-style)
      # The bucket is the first component of the path.
      if host_parts.first == 's3' || host_parts.first.match?(/^s3(?:[-.][a-zA-Z0-9]+)?$/)
        path_segments = key.split('/', 2) # Split only on the first slash
        if path_segments.length > 1
          bucket = path_segments.first
          actual_key = path_segments.last
          return [bucket, actual_key]
        elsif path_segments.length == 1
          # This could be a bucket name if the key is empty (e.g. accessing bucket root)
          # Or if the path is just the bucket name (no key)
          # For simplicity, if there's only one part, and it's for file processing, this is likely ambiguous
          # or an incomplete path for a file.
          # However, if the job expects to list bucket contents, this might be valid.
          # For now, assume we need a key after the bucket.
          # If path_segments.first is the bucket, and no key, what to do?
          # The original code didn't handle this well either.
          # Let's assume for file processing, a key must exist after the bucket in path-style.
          return [nil, nil] # Or return [path_segments.first, ''] if that's valid
        end
      end
    end
    [nil, nil] # Default if no format matches
  end
end
