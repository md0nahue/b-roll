# frozen_string_literal: true

require 'httparty'
require 'json'
require 'pathname'
require 'tempfile'
require 'open3'
require 'logger'
require 'time'

module Groq
  # Groq::Transcriber
  #
  # A Ruby class to interact with the Groq API for speech-to-text transcription.
  # It is designed to handle large audio files by automatically splitting them
  # into chunks, transcribing each chunk, and intelligently merging the results.
  #
  # Dependencies:
  # - httparty: For making HTTP requests to the Groq API.
  # - A system installation of FFmpeg for audio processing.
  #
  # Example Usage (Conceptual):
  #   transcriber = Groq::Transcriber.new(api_key: 'YOUR_GROQ_API_KEY')
  #   result = transcriber.transcribe(file_path: 'path/to/your/audio.mp3')
  #   puts result['text']
  #
  class Transcriber
    include HTTParty

    # Groq API endpoint for audio transcriptions.
    base_uri 'https://api.groq.com/openai/v1/audio'

    # Supported models for transcription (can be expanded based on Groq documentation).
    # Using a simplified list for now.
    MODELS = {
      transcription: [
        'whisper-large-v3-turbo',
        'distil-whisper-large-v3-en',
        'whisper-large-v3'
      ]
    }.freeze

    # Default options for transcription requests.
    DEFAULT_OPTIONS = {
      chunk_length_sec: 600,  # 10 minutes per chunk (600 seconds)
      overlap_sec: 15,        # 15-second overlap
      model: 'whisper-large-v3-turbo', # Default model
      language: 'en',         # Default language
      response_format: 'verbose_json', # Required for timestamps
      timestamp_granularities: %w[segment word], # Get both segment and word timestamps
      temperature: 0.0,       # Recommended for transcription
      retries: 3,             # Number of retries for API calls
      retry_delay_sec: 60     # Delay between retries
    }.freeze

    attr_reader :api_key, :options, :logger

    # Initializes a new Transcriber instance.
    #
    # @param api_key [String] The Groq API key. Defaults to ENV['GROQ_API_KEY'].
    # @param default_options [Hash] A hash of default settings.
    # @param logger [Logger] A logger instance.
    def initialize(api_key: nil, default_options: {}, logger: nil)
      @api_key = api_key || ENV.fetch('GROQ_API_KEY', nil)
      if @api_key.nil? || @api_key.empty?
        raise ArgumentError, 'Groq API key is not provided or set in ENV["GROQ_API_KEY"]'
      end

      @options = DEFAULT_OPTIONS.merge(default_options)
      @logger = logger || Logger.new($stdout)
      @logger.level = Logger::INFO # Default logging level

      check_ffmpeg_installed!
      @logger.info("Groq::Transcriber initialized. Model: #{@options[:model]}, Chunk: #{@options[:chunk_length_sec]}s, Overlap: #{@options[:overlap_sec]}s")
    end

    # Transcribes an audio file using the Groq API by chunking.
    #
    # @param file_path [String, Pathname] Path to the input audio file.
    # @param output_dir_name [String] Directory to save transcription files.
    #        Only used if `save_files` is true.
    # @param save_files [Boolean] If true, saves .txt and .json results to `output_dir_name`.
    # @param job_options [Hash] Keyword arguments to override instance defaults for this specific transcription job.
    #        See DEFAULT_OPTIONS for available keys (e.g., :model, :language, :chunk_length_sec).
    # @return [Hash] A hash containing the merged transcription with 'text', 'segments', and 'words'.
    # @raise [ArgumentError] If file_path is not found.
    # @raise [RuntimeError] If any critical step of the transcription process fails.
    def transcribe(file_path:, output_dir_name: 'transcriptions', save_files: true, **job_options)
      overall_start_time = Time.now
      @logger.info("Starting transcription process for: #{file_path}")

      input_pathname = Pathname.new(file_path)
      raise ArgumentError, "Input audio file not found: #{input_pathname}" unless input_pathname.exist?

      # Merge instance options with per-job options
      current_job_options = @options.merge(job_options)
      @logger.debug("Current job options: #{current_job_options}")

      preprocessed_audio_file = nil # Ensure it's in scope for ensure block
      begin
        # 1. Preprocess audio
        @logger.info("Step 1: Preprocessing audio...")
        preprocessed_audio_file = preprocess_audio(input_pathname)
        @logger.info("Audio preprocessed to: #{preprocessed_audio_file}")

        # 2. Get audio duration
        @logger.info("Step 2: Getting audio duration...")
        duration_ms = get_audio_duration_ms(preprocessed_audio_file)
        if duration_ms == 0
            @logger.warn("Audio duration is 0ms. Skipping transcription. File: #{preprocessed_audio_file}")
            # Clean up preprocessed file before returning
            preprocessed_audio_file.unlink if preprocessed_audio_file&.exist?
            return { 'text' => '', 'segments' => [], 'words' => [] }
        end


        # 3. Generate chunk information
        @logger.info("Step 3: Generating chunk information...")
        chunks = generate_chunks_info(duration_ms, current_job_options)
        if chunks.empty? && duration_ms > 0
          @logger.warn("No chunks were generated for a non-empty audio file. This might indicate an issue with chunking logic or very short audio not meeting thresholds.")
          # Potentially create a single chunk for the whole audio if it's short but generate_chunks_info didn't handle it
           chunks << { index: 0, start_ms: 0, end_ms: duration_ms }
           @logger.info("Created a single fallback chunk for the entire audio.")
        elsif chunks.empty? && duration_ms == 0
           @logger.info("No chunks generated as audio duration is zero.")
           preprocessed_audio_file.unlink if preprocessed_audio_file&.exist?
           return { 'text' => '', 'segments' => [], 'words' => [] }
        end
        @logger.info("Generated #{chunks.size} chunks to process.")

        # 4. Transcribe each chunk
        @logger.info("Step 4: Transcribing #{chunks.size} chunks...")
        transcription_results_with_start_time = []
        total_api_transcription_time = 0

        chunks.each_with_index do |chunk_info, idx|
          chunk_num_for_log = idx + 1 # 1-based for logging
          @logger.info("Processing chunk #{chunk_num_for_log}/#{chunks.size} (Time: #{(chunk_info[:start_ms]/1000.0).round(1)}s - #{(chunk_info[:end_ms]/1000.0).round(1)}s)")

          api_response, api_time = transcribe_chunk(
            preprocessed_audio_file,
            chunk_info,
            current_job_options,
            chunk_num_for_log,
            chunks.size
          )
          total_api_transcription_time += api_time
          transcription_results_with_start_time << { result: api_response, start_ms: chunk_info[:start_ms] }
        end
        @logger.info("All chunks transcribed. Total Groq API time: #{total_api_transcription_time.round(2)}s")

        # 5. Merge transcriptions
        @logger.info("Step 5: Merging transcription results...")
        final_merged_result = merge_transcripts(transcription_results_with_start_time, current_job_options)

        # 6. Save results (optional)
        if save_files
          @logger.info("Step 6: Saving results...")
          saved_to_path = save_results(final_merged_result, input_pathname, output_dir_name)
          @logger.info("Results saved with base path: #{saved_to_path}")
        else
          @logger.info("Step 6: Skipping saving results as per 'save_files' option.")
        end

        overall_duration = Time.now - overall_start_time
        @logger.info("Transcription process completed in #{overall_duration.round(2)}s.")

        return final_merged_result

      rescue ArgumentError => e # Catch specific argument errors (e.g. file not found from this method)
        @logger.error("ArgumentError in transcription process: #{e.message}")
        raise
      rescue RuntimeError => e # Catch runtime errors from private methods (ffmpeg, ffprobe, API errors)
        @logger.error("RuntimeError in transcription process: #{e.message}")
        # Add more context if needed, or specific error types from private methods
        raise
      rescue StandardError => e
        @logger.error("An unexpected error occurred during the transcription process: #{e.message}")
        @logger.error(e.backtrace.join("\n"))
        raise "Transcription failed due to an unexpected error: #{e.message}"
      ensure
        # Cleanup: Delete the temporary preprocessed audio file
        if preprocessed_audio_file&.exist?
          preprocessed_audio_file.unlink
          @logger.info("Cleaned up temporary preprocessed file: #{preprocessed_audio_file}")
        end
      end
    end

    private

    def check_ffmpeg_installed!
      @logger.debug('Checking for FFmpeg installation...')
      _stdout, stderr, status = Open3.capture3('ffmpeg -version')
      if status.success?
        @logger.info('FFmpeg found.')
        return true
      else
        @logger.error("FFmpeg check failed. Stderr: #{stderr}")
        raise 'FFmpeg not found or not working. Please install FFmpeg and ensure it is in your system PATH.'
      end
    rescue Errno::ENOENT
      @logger.error('FFmpeg command not found. Errno::ENOENT.')
      raise 'FFmpeg not found. Please install FFmpeg and ensure it is in your system PATH.'
    end

    # Converts the input audio file to 16kHz mono FLAC format using FFmpeg.
    #
    # @param input_path [Pathname] Path to the input audio file.
    # @return [Pathname] Path to the temporary processed FLAC file.
    # @raise [RuntimeError] If FFmpeg conversion fails.
    def preprocess_audio(input_path)
      unless input_path.exist?
        @logger.error("Input audio file not found: #{input_path}")
        raise "Input audio file not found: #{input_path}"
      end

      # Create a temporary file for the output, ensuring it has the .flac extension
      # and will be cleaned up automatically.
      temp_flac_file = Tempfile.new(['groq_preprocessed_audio_', '.flac'])
      temp_flac_file.close # Close the file so FFmpeg can write to it
      output_path = Pathname.new(temp_flac_file.path)

      @logger.info("Preprocessing audio: #{input_path} to #{output_path}")
      @logger.info("Converting to 16kHz mono FLAC...")

      # FFmpeg command arguments
      cmd = [
        'ffmpeg',
        '-hide_banner',      # Suppress printing banner
        '-loglevel', 'error', # Only log errors
        '-i', input_path.to_s, # Input file
        '-ar', '16000',        # Audio sample rate: 16kHz
        '-ac', '1',            # Audio channels: 1 (mono)
        '-c:a', 'flac',        # Audio codec: flac
        '-y',                  # Overwrite output files without asking
        output_path.to_s       # Output file
      ]

      @logger.debug("Executing FFmpeg command: #{cmd.join(' ')}")
      stdout, stderr, status = Open3.capture3(*cmd)

      if status.success?
        @logger.info("Audio preprocessing successful: #{output_path}")
        return output_path
      else
        # Ensure temporary file is cleaned up on failure before raising
        output_path.unlink if output_path.exist?
        @logger.error("FFmpeg conversion failed for #{input_path}.")
        @logger.error("FFmpeg stdout: #{stdout}") unless stdout.empty?
        @logger.error("FFmpeg stderr: #{stderr}") unless stderr.empty?
        raise "FFmpeg conversion failed. Standard Error: #{stderr}"
      end
    rescue StandardError => e
      # Ensure temporary file is cleaned up on any unexpected error
      output_path.unlink if output_path&.exist?
      @logger.error("An unexpected error occurred during preprocessing: #{e.message}")
      raise
    end

    # ... (further private methods will be added here) ...

    # Retrieves the duration of an audio file in milliseconds using ffprobe.
    #
    # @param file_path [Pathname] Path to the audio file.
    # @return [Integer] Duration of the audio file in milliseconds.
    # @raise [RuntimeError] If ffprobe fails or cannot determine duration.
    def get_audio_duration_ms(file_path)
      unless file_path.exist?
        @logger.error("Audio file for duration check not found: #{file_path}")
        raise "Audio file not found: #{file_path}"
      end

      @logger.info("Getting duration for: #{file_path}")
      cmd = [
        'ffprobe',
        '-v', 'error',
        '-show_entries', 'format=duration',
        '-of', 'default=noprint_wrappers=1:nokey=1',
        file_path.to_s
      ]

      @logger.debug("Executing ffprobe command: #{cmd.join(' ')}")
      stdout, stderr, status = Open3.capture3(*cmd)

      if status.success? && !stdout.strip.empty?
        duration_seconds = stdout.strip.to_f
        duration_ms = (duration_seconds * 1000).to_i
        @logger.info("Audio duration: #{duration_seconds.round(2)}s (#{duration_ms}ms)")
        return duration_ms
      else
        @logger.error("ffprobe failed to get duration for #{file_path}.")
        @logger.error("ffprobe stdout: #{stdout}") unless stdout.empty?
        @logger.error("ffprobe stderr: #{stderr}") unless stderr.empty?
        raise "ffprobe failed to get duration. Standard Error: #{stderr}"
      end
    rescue StandardError => e
      @logger.error("An unexpected error occurred while getting audio duration: #{e.message}")
      raise
    end

    # Generates information for each chunk based on total duration, chunk length, and overlap.
    #
    # @param total_duration_ms [Integer] Total duration of the audio in milliseconds.
    # @param chunk_options [Hash] Options containing :chunk_length_sec and :overlap_sec.
    # @return [Array<Hash>] An array of hashes, each representing a chunk with :start_ms and :end_ms.
    def generate_chunks_info(total_duration_ms, chunk_options)
      chunk_length_ms = chunk_options[:chunk_length_sec] * 1000
      overlap_ms = chunk_options[:overlap_sec] * 1000

      chunks = []
      current_pos_ms = 0

      if chunk_length_ms <= overlap_ms
        @logger.error("Chunk length (#{chunk_length_ms}ms) must be greater than overlap (#{overlap_ms}ms).")
        raise ArgumentError, "Chunk length must be greater than overlap."
      end

      @logger.info("Generating chunks: Total duration: #{total_duration_ms}ms, Chunk length: #{chunk_length_ms}ms, Overlap: #{overlap_ms}ms")

      idx = 0
      while current_pos_ms < total_duration_ms
        start_ms = current_pos_ms
        end_ms = current_pos_ms + chunk_length_ms
        end_ms = [end_ms, total_duration_ms].min # Ensure end_ms does not exceed total duration

        chunks << { index: idx, start_ms: start_ms, end_ms: end_ms }
        @logger.debug("Generated chunk #{idx}: Start: #{start_ms}ms, End: #{end_ms}ms")

        idx += 1
        current_pos_ms += (chunk_length_ms - overlap_ms)
        # Break if the next starting position is effectively at or beyond the total duration
        break if current_pos_ms >= total_duration_ms && (start_ms + chunk_length_ms >= total_duration_ms)
      end

      # Ensure the very last bit of audio is captured if the loop condition caused an early exit
      if !chunks.empty? && chunks.last[:end_ms] < total_duration_ms && current_pos_ms < total_duration_ms
         start_ms = current_pos_ms
         end_ms = total_duration_ms
         chunks << { index: idx, start_ms: start_ms, end_ms: end_ms }
         @logger.debug("Generated final adjusted chunk #{idx}: Start: #{start_ms}ms, End: #{end_ms}ms")
      elsif chunks.empty? && total_duration_ms > 0 # Handle very short audio files as a single chunk
        chunks << { index: 0, start_ms: 0, end_ms: total_duration_ms }
        @logger.debug("Generated single chunk for short audio: Start: 0ms, End: #{total_duration_ms}ms")
      end


      @logger.info("Generated #{chunks.size} chunks.")
      chunks
    end

    # ... (further private methods will be added here) ...

    # Extracts a specific audio segment to a temporary FLAC file using FFmpeg.
    #
    # @param source_audio_path [Pathname] Path to the source (preprocessed) audio file.
    # @param chunk_info [Hash] A hash with :start_ms and :end_ms for the chunk.
    # @return [Tempfile] A Tempfile object containing the extracted audio chunk in FLAC format.
    #         The caller is responsible for closing and unlinking this Tempfile.
    # @raise [RuntimeError] If FFmpeg fails to extract the chunk.
    def extract_chunk_to_temp_file(source_audio_path, chunk_info)
      temp_chunk_file = Tempfile.new(["groq_chunk_", ".flac"])
      # We call .close here so that FFmpeg can write to this path.
      # The file still exists until .unlink is called.
      temp_chunk_file.close
      output_path = Pathname.new(temp_chunk_file.path)

      start_seconds = chunk_info[:start_ms] / 1000.0
      end_seconds = chunk_info[:end_ms] / 1000.0
      duration_seconds = end_seconds - start_seconds

      if duration_seconds <= 0
        # FFmpeg will error with non-positive duration, handle this case.
        # Create an empty FLAC file or handle as appropriate.
        # For now, let's log and return the empty temp file, API might handle it.
        @logger.warn("Chunk duration is zero or negative for chunk starting at #{start_seconds}s. Proceeding with empty chunk.")
        # Fall through to return the empty temp_chunk_file, which ffmpeg won't modify.
        # Or, write a minimal valid FLAC header if needed, but often not necessary for robust APIs.
        return temp_chunk_file # Pathname.new(temp_chunk_file.path)
      end

      @logger.info("Extracting chunk: #{source_audio_path} (Start: #{start_seconds.round(2)}s, Duration: #{duration_seconds.round(2)}s) to #{output_path}")

      cmd = [
        'ffmpeg',
        '-hide_banner',
        '-loglevel', 'error',
        '-i', source_audio_path.to_s,
        '-ss', start_seconds.to_s, # Start time
        '-t', duration_seconds.to_s, # Duration
        '-c:a', 'flac', # Output codec
        # '-c:a', 'copy', # If source is already FLAC and no manipulation needed beyond seeking
        '-y',
        output_path.to_s
      ]

      @logger.debug("Executing FFmpeg chunk extraction command: #{cmd.join(' ')}")
      _stdout, stderr, status = Open3.capture3(*cmd)

      unless status.success?
        output_path.unlink if output_path.exist? # Clean up on failure
        @logger.error("FFmpeg chunk extraction failed for chunk #{chunk_info[:index]}.")
        @logger.error("FFmpeg stderr: #{stderr}") unless stderr.empty?
        raise "FFmpeg chunk extraction failed. Standard Error: #{stderr}"
      end

      @logger.debug("Chunk extracted successfully: #{output_path}")
      return temp_chunk_file # Return the tempfile object itself
    end

    # Transcribes a single audio chunk using the Groq API.
    #
    # @param preprocessed_audio_path [Pathname] Path to the full preprocessed audio file.
    # @param chunk_info [Hash] Hash containing :start_ms, :end_ms, and :index for the current chunk.
    # @param job_options [Hash] Transcription options for this job.
    # @param chunk_num [Integer] The 1-based index of the current chunk for logging.
    # @param total_chunks [Integer] Total number of chunks for logging.
    # @return [Array<Hash, Float>] A tuple containing the parsed API response (Hash) and API call time (Float).
    # @raise [RuntimeError] If transcription fails after retries.
    def transcribe_chunk(preprocessed_audio_path, chunk_info, job_options, chunk_num, total_chunks)
      total_api_time_for_chunk = 0
      retries_left = job_options[:retries]

      temp_chunk_file_object = nil # To ensure it's in scope for ensure block

      begin
        temp_chunk_file_object = extract_chunk_to_temp_file(preprocessed_audio_path, chunk_info)

        # Check if the extracted chunk file is empty or too small, which might indicate an issue.
        # Groq API minimum is 0.01 seconds. A FLAC header alone is ~44 bytes.
        # Let's assume a minimal check for a few hundred bytes to ensure it's not just an empty file.
        if File.size(temp_chunk_file_object.path) < 100
            @logger.warn("Chunk #{chunk_num}/#{total_chunks} (Time: #{(chunk_info[:start_ms]/1000.0).round(1)}s-#{(chunk_info[:end_ms]/1000.0).round(1)}s) is very small or empty (size: #{File.size(temp_chunk_file_object.path)} bytes). Skipping API call, returning empty result.")
            # Return a structure that merge_transcripts can handle, e.g., empty text and no words/segments.
            return [{ 'text' => '', 'words' => [], 'segments' => [] }, 0.0]
        end

        loop do # Retry loop
          api_call_start_time = Time.now

          # The file needs to be opened in binary read mode for httparty
          File.open(temp_chunk_file_object.path, 'rb') do |file_for_upload|
            options_for_api = {
              headers: { 'Authorization' => "Bearer #{@api_key}" },
              body: {
                file: file_for_upload, # Pass the file object
                model: job_options[:model],
                language: job_options[:language],
                response_format: job_options[:response_format],
                # Ensure timestamp_granularities is an array for the API
                timestamp_granularities: Array(job_options[:timestamp_granularities]),
                temperature: job_options[:temperature].to_f
              },
              # Consider a timeout for the API request itself
              timeout: job_options.fetch(:api_timeout_sec, 300) # Default 5 min timeout for API call
            }
            # Add prompt if present and not empty
            options_for_api[:body][:prompt] = job_options[:prompt] if job_options[:prompt] && !job_options[:prompt].empty?

            @logger.info("Transcribing chunk #{chunk_num}/#{total_chunks} (Time: #{(chunk_info[:start_ms]/1000.0).round(1)}s-#{(chunk_info[:end_ms]/1000.0).round(1)}s) with model #{job_options[:model]}")
            @logger.debug("API Request Body (excluding file): #{options_for_api[:body].reject { |k, _v| k == :file }}")

            response = self.class.post('/transcriptions', options_for_api)
            api_call_duration = Time.now - api_call_start_time
            total_api_time_for_chunk += api_call_duration

            if response.success?
              @logger.info("Chunk #{chunk_num}/#{total_chunks} processed successfully in #{api_call_duration.round(2)}s.")
              parsed_response = JSON.parse(response.body)
              return [parsed_response, total_api_time_for_chunk]
            elsif response.code == 429 && retries_left > 0 # Rate limit
              retries_left -= 1
              wait_time = job_options[:retry_delay_sec]
              @logger.warn("Rate limit hit for chunk #{chunk_num}. Retrying in #{wait_time}s... (#{retries_left} retries left). Body: #{response.body}")
              sleep wait_time
            elsif response.code == 400 && response.body.include?("Invalid file format")
               @logger.error("API Error for chunk #{chunk_num}: Invalid file format. Size: #{File.size(temp_chunk_file_object.path)} bytes. Response: #{response.code} - #{response.body}")
               # Don't retry on this error, it's likely a problem with the chunk itself.
               raise "API Error: Invalid file format for chunk #{chunk_num}. Groq API could not process the audio chunk."
            else # Other API errors
              @logger.error("API Error for chunk #{chunk_num}: #{response.code} - #{response.body}")
              raise "API Error: #{response.code} for chunk #{chunk_num}. Response: #{response.body}" # Don't retry on unspecified server errors immediately
            end
          end # File.open
        end # Retry loop
      rescue Net::ReadTimeout, Net::OpenTimeout => e
        if retries_left > 0
          retries_left -= 1
          wait_time = job_options[:retry_delay_sec]
          @logger.warn("Network timeout for chunk #{chunk_num} (#{e.class.name}). Retrying in #{wait_time}s... (#{retries_left} retries left).")
          sleep wait_time
          retry # Go to the beginning of the begin block for this attempt
        else
          @logger.error("Network timeout for chunk #{chunk_num} after multiple retries: #{e.message}")
          raise "Network timeout after multiple retries for chunk #{chunk_num}: #{e.message}"
        end
      rescue StandardError => e
        @logger.error("Error transcribing chunk #{chunk_num}: #{e.message}")
        @logger.error(e.backtrace.join("\n"))
        raise # Re-raise the caught error
      ensure
        if temp_chunk_file_object
          temp_chunk_file_object.unlink # This deletes the temp file
          @logger.debug("Temporary chunk file #{temp_chunk_file_object.path} unlinked.")
        end
      end
    end

    # ... (further private methods will be added here) ...

    # Aligns and merges two potentially overlapping text sequences.
    # This is a simplified version focusing on trimming based on common suffix/prefix.
    # A more sophisticated version might use sequence alignment algorithms.
    #
    # @param text1 [String] The text from the first (earlier) segment.
    # @param text2 [String] The text from the second (later) segment, which might overlap.
    # @param overlap_char_estimate [Integer] An estimate of how many characters might overlap.
    # @return [String] The merged text.
    def align_and_merge_text_sequences(text1, text2, overlap_char_estimate = 100)
      return text1 if text2.nil? || text2.strip.empty?
      return text2 if text1.nil? || text1.strip.empty?

      text1_stripped = text1.strip
      text2_stripped = text2.strip

      # Simple strategy: if one contains the other (common for full sentence overlaps)
      return text2_stripped if text1_stripped.include?(text2_stripped) && text1_stripped.length > text2_stripped.length
      return text1_stripped if text2_stripped.include?(text1_stripped) && text2_stripped.length > text1_stripped.length

      # More advanced approach similar to Python's find_longest_common_sequence (conceptual)
      # This is a placeholder for the logic described in the Python `find_longest_common_sequence`
      # which involves splitting into words and finding optimal alignment.
      # For now, we'll use a simpler heuristic: find longest common suffix of text1 that is a prefix of text2.

      max_overlap_len = 0
      # Consider a reasonable portion of the end of text1 and start of text2
      # Limit search space to avoid excessive computation on very long segments
      len1 = text1_stripped.length
      len2 = text2_stripped.length
      search_len = [len1, len2, overlap_char_estimate].min

      # Iterate from a plausible overlap length down to a minimum
      (search_len).downto(1) do |k|
        suffix_t1 = text1_stripped[len1-k, k]
        prefix_t2 = text2_stripped[0, k]
        if suffix_t1 == prefix_t2
          max_overlap_len = k
          break
        end
      end

      if max_overlap_len > 0
        # Found an overlap
        # Text1 up to the overlap + the overlapping part (from text1 or text2) + rest of text2
        # More simply: text1 + non-overlapping part of text2
        return text1_stripped + text2_stripped[max_overlap_len..-1]
      else
        # No significant textual overlap found, concatenate with a space
        # This might happen if overlap is purely silence or very different transcriptions
        return "#{text1_stripped} #{text2_stripped}"
      end
    end

    # Merges transcription results from multiple chunks.
    #
    # @param chunk_results [Array<Hash>] An array of hashes, where each hash contains
    #        :result (the API response for a chunk) and :start_ms (the chunk's original start time).
    # @param job_options [Hash] Current job's options, e.g., for overlap settings.
    # @return [Hash] A hash containing the merged 'text', 'segments', and 'words'.
    def merge_transcripts(chunk_results, job_options)
      @logger.info("Merging #{chunk_results.size} chunk results...")

      all_words = []
      all_segments = []

      # 1. Adjust all timestamps to be absolute and collect all words/segments
      chunk_results.each_with_index do |res_info, chunk_idx|
        api_result = res_info[:result]
        chunk_start_time_sec = res_info[:start_ms] / 1000.0

        (api_result['words'] || []).each do |word|
          adjusted_word = word.dup
          adjusted_word['start'] = (word['start'].to_f + chunk_start_time_sec).round(3)
          adjusted_word['end'] = (word['end'].to_f + chunk_start_time_sec).round(3)
          adjusted_word['chunk_index'] = chunk_idx # Keep track of origin
          all_words << adjusted_word
        end

        (api_result['segments'] || []).each do |segment|
          adjusted_segment = segment.dup
          adjusted_segment['start'] = (segment['start'].to_f + chunk_start_time_sec).round(3)
          adjusted_segment['end'] = (segment['end'].to_f + chunk_start_time_sec).round(3)
          adjusted_segment['chunk_index'] = chunk_idx # Keep track of origin
          # Ensure 'words' within segments also get adjusted if they exist and are not just IDs
          if adjusted_segment['words'] && adjusted_segment['words'].is_a?(Array)
            adjusted_segment['words'] = adjusted_segment['words'].map do |seg_word|
              seg_word_copy = seg_word.dup
              seg_word_copy['start'] = (seg_word['start'].to_f + chunk_start_time_sec).round(3)
              seg_word_copy['end'] = (seg_word['end'].to_f + chunk_start_time_sec).round(3)
              seg_word_copy
            end
          end
          all_segments << adjusted_segment
        end
      end

      # Sort by start time, then by chunk index to maintain order from API for ties
      all_words.sort_by! { |w| [w['start'], w['chunk_index']] }
      all_segments.sort_by! { |s| [s['start'], s['chunk_index']] }

      # 2. De-duplicate words (simple de-duplication based on start time and text)
      # A more robust approach might consider end times and confidence scores.
      final_words = all_words.uniq { |w| "#{w['start'].round(2)}_#{w['word']}" }

      # 3. Merge segments, handling overlaps (this is the complex part)
      final_segments = []
      if !all_segments.empty?
        final_segments << all_segments.first.dup # Start with the first segment

        all_segments[1..-1].each do |current_segment|
          last_final_segment = final_segments.last

          # Check for overlap: current starts before last one ended
          overlap_amount = last_final_segment['end'] - current_segment['start']

          if overlap_amount > 0
            # We have an overlap in time. Now, try to merge text.
            # Estimate character overlap based on time overlap and typical speech rate (e.g., 15 chars/sec)
            # This is a rough heuristic.
            estimated_char_overlap = (overlap_amount * 15).to_i

            merged_text = align_and_merge_text_sequences(last_final_segment['text'], current_segment['text'], estimated_char_overlap)

            last_final_segment['text'] = merged_text
            last_final_segment['end'] = [last_final_segment['end'], current_segment['end']].max # Extend to cover both

            # Other metadata (avg_logprob, etc.) from `current_segment` could be merged if needed,
            # e.g., by averaging or taking the one from the longer part of the merged text.
            # For simplicity, we're keeping the metadata of `last_final_segment` and just extending its text/end time.
            # We might want to merge 'words' inside segments too, but that adds complexity.
          else
            # No time overlap, or current_segment starts after/at the end of last_final_segment
            final_segments << current_segment.dup
          end
        end
      end

      # 4. Reconstruct final text from the clean, merged segments
      final_text = final_segments.map { |s| s['text']&.strip }.compact.join(' ')

      @logger.info("Merging complete. Final text length: #{final_text.length} chars. Segments: #{final_segments.size}. Words: #{final_words.size}.")

      # Clean up temporary chunk_index from words and segments
      final_words.each { |w| w.delete('chunk_index') }
      final_segments.each { |s| s.delete('chunk_index') }

      {
        'text' => final_text,
        'segments' => final_segments,
        'words' => final_words
      }
    end

    # ... (further private methods will be added here) ...

    # Saves the final transcription results to various file formats.
    #
    # @param result_hash [Hash] The final merged transcription data
    #        (expected to have 'text', 'segments', 'words' keys).
    # @param original_audio_path [Pathname] Path to the original audio file, used for naming output files.
    # @param output_directory_name [String] Name of the directory to save files into.
    # @return [Pathname] The base path used for saving the set of files.
    # @raise [IOError] If saving any of the files fails.
    def save_results(result_hash, original_audio_path, output_directory_name)
      base_output_dir = Pathname.new(output_directory_name)
      begin
        base_output_dir.mkdir unless base_output_dir.exist?
      rescue SystemCallError => e
        @logger.error("Failed to create output directory #{base_output_dir}: #{e.message}")
        raise IOError, "Cannot create output directory: #{e.message}"
      end

      timestamp = Time.now.strftime('%Y%m%d_%H%M%S')
      original_basename = original_audio_path.basename(original_audio_path.extname).to_s
      # Sanitize basename to prevent issues with special characters in filenames
      sanitized_basename = original_basename.gsub(/[^0-9A-Za-z._-]/, '_')

      base_filename = "#{sanitized_basename}_#{timestamp}"
      output_base_path = base_output_dir.join(base_filename)

      files_saved = []

      begin
        # Save plain text (.txt)
        txt_path = Pathname.new("#{output_base_path}.txt")
        File.write(txt_path, result_hash['text'])
        files_saved << txt_path
        @logger.info("Saved plain text transcription to: #{txt_path}")

        # Save full JSON (_full.json)
        full_json_path = Pathname.new("#{output_base_path}_full.json")
        File.write(full_json_path, JSON.pretty_generate(result_hash))
        files_saved << full_json_path
        @logger.info("Saved full JSON transcription to: #{full_json_path}")

        # Save segments-only JSON (_segments.json)
        segments_json_path = Pathname.new("#{output_base_path}_segments.json")
        File.write(segments_json_path, JSON.pretty_generate(result_hash['segments'] || []))
        files_saved << segments_json_path
        @logger.info("Saved segments JSON to: #{segments_json_path}")

        return output_base_path # Return the base path used for the files

      rescue SystemCallError, IOError => e
        @logger.error("Error saving transcription results for base path #{output_base_path}: #{e.message}")
        # Optional: Attempt to clean up partially saved files if desired
        # files_saved.each { |f| f.unlink if f.exist? }
        raise IOError, "Failed to save one or more result files: #{e.message}"
      end
    end

  end
end
