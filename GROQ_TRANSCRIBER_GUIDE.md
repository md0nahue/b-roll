# Groq::Transcriber Usage Guide

The `Groq::Transcriber` class provides a Ruby interface to interact with the Groq API for speech-to-text transcription. It's designed to handle large audio files by automatically splitting them into manageable chunks, transcribing each chunk, and then intelligently merging the results into a coherent transcript.

## 1. Prerequisites

Before using this class, ensure you have the following installed and configured:

1.  **Ruby:** Version 2.7 or newer is recommended.
2.  **FFmpeg:** The FFmpeg multimedia framework must be installed on your system and accessible via the system's `PATH`. The `Groq::Transcriber` class relies on `ffmpeg` for audio preprocessing (to convert audio to 16kHz mono FLAC) and `ffprobe` (usually part of FFmpeg) to get audio duration.
    *   **Installation:**
        *   macOS: `brew install ffmpeg`
        *   Debian/Ubuntu: `sudo apt update && sudo apt install ffmpeg`
        *   Windows: Download from [ffmpeg.org](https://ffmpeg.org/download.html) and add to your system's PATH.
3.  **Groq API Key:** You need an active API key from [Groq Cloud](https://console.groq.com/keys).

## 2. Installation & Setup

Follow these steps to integrate the `Groq::Transcriber` class into your Ruby project:

### Step 1: Place the Class File

Ensure the `groq_transcriber.rb` file (containing the `Groq::Transcriber` class) is placed in your project, typically in the `lib/` directory.

```
your_project/
├── lib/
│   └── groq_transcriber.rb
├── Gemfile
└── your_script.rb
```

### Step 2: Add Dependencies to Gemfile

The class depends on the `httparty` gem for making HTTP requests. Add it to your project's `Gemfile`:

```ruby
# Gemfile
source 'https://rubygems.org'

gem 'httparty'
# Other gems your project might need...
```

Then, run Bundler to install the gem and update your `Gemfile.lock`:

```bash
bundle install
```
If you are not using Bundler, you can install the gem system-wide (not recommended for project-specific dependencies):
```bash
gem install httparty
```

### Step 3: Configure Your Groq API Key

The `Groq::Transcriber` class requires your Groq API key. You can provide it in two ways:

*   **(Recommended) Environment Variable:** Set the `GROQ_API_KEY` environment variable in your system or application environment.
    ```bash
    export GROQ_API_KEY='your-actual-groq-api-key'
    ```
*   **(Alternative) Pass to Constructor:** You can pass the API key directly when creating an instance of the class (see example usage).

## 3. Class API Reference

### `Groq::Transcriber.new(api_key: nil, default_options: {}, logger: nil)`

This is the constructor to create a new transcriber instance.

*   `api_key` (String, optional): Your Groq API key. If `nil` or not provided, the class will attempt to fetch it from the `GROQ_API_KEY` environment variable. An `ArgumentError` will be raised if the key is not found.
*   `default_options` (Hash, optional): A hash to override the default settings for all transcription jobs run with this instance. See "Available Options" below for details.
*   `logger` (Logger, optional): An instance of Ruby's `Logger` class (from `require 'logger'`). If not provided, a new logger instance writing to `STDOUT` with `INFO` level will be created.

### `transcriber.transcribe(file_path:, output_dir_name: 'transcriptions', save_files: true, **job_options)`

This is the main public method to start a transcription job.

*   `file_path:` (String or Pathname, **required**): The full path to the audio file you want to transcribe (e.g., `.mp3`, `.wav`, `.m4a`, `.flac`).
*   `output_dir_name:` (String, optional, default: `'transcriptions'`): The directory where output files (`.txt`, `_full.json`, `_segments.json`) will be saved if `save_files` is true. The directory will be created if it doesn't exist.
*   `save_files:` (Boolean, optional, default: `true`): If `true`, the transcription results will be saved to files in the `output_dir_name`. If `false`, no files will be created.
*   `**job_options` (Hash, optional keyword arguments): A set of options to override the instance's default settings for this specific transcription job. See "Available Options" below.

**Returns:**
A `Hash` containing the final, merged transcription. The structure is:
```json
{
  "text": "The full transcribed text goes here...",
  "segments": [
    {
      "id": 0, // Segment ID from Groq (may not be contiguous after merging)
      "seek": 0, // Seek offset from Groq
      "start": 0.0, // Absolute start time in seconds
      "end": 5.23,  // Absolute end time in seconds
      "text": " First segment of text.",
      "tokens": [50364, 1701, ...], // Token IDs
      "temperature": 0.0,
      "avg_logprob": -0.12345,
      "compression_ratio": 1.5,
      "no_speech_prob": 0.01
      // Potentially other metadata from Groq API
    }
    // ... more segments
  ],
  "words": [
    { "word": "First", "start": 0.0, "end": 0.45 },
    { "word": "segment", "start": 0.5, "end": 1.02 }
    // ... more words with absolute start/end times in seconds
  ]
}
```

**Raises:**
*   `ArgumentError`: If the `file_path` is not found or if the API key is missing.
*   `RuntimeError`: For critical errors during the process (e.g., FFmpeg failure, non-recoverable API errors).
*   Other network or file system related errors.

### Available Options

These options can be set in `default_options` during initialization or passed as keyword arguments to the `transcribe` method.

| Key                       | Type             | Default Value                    | Description                                                                                                                                                             |
| ------------------------- | ---------------- | -------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `:chunk_length_sec`       | Integer          | `600` (10 minutes)               | The length of each audio chunk in seconds. Groq API has limits on file size per request, so chunking is necessary for large files.                                     |
| `:overlap_sec`            | Integer          | `15`                             | The duration of the overlap between consecutive chunks in seconds. This helps ensure contextual continuity and prevent words from being cut off at chunk boundaries.      |
| `:model`                  | String           | `'whisper-large-v3-turbo'`       | The ID of the Groq Whisper model to use (e.g., `'whisper-large-v3'`, `'distil-whisper-large-v3-en'`).                                                                  |
| `:language`               | String           | `'en'`                           | The language of the audio in [ISO-639-1 format](https://en.wikipedia.org/wiki/List_of_ISO_639-1_codes) (e.g., `'es'`, `'fr'`). Specifying this improves accuracy and speed. |
| `:response_format`        | String           | `'verbose_json'`                 | The format of the API response. `'verbose_json'` is required to get timestamps and other detailed metadata.                                                           |
| `:timestamp_granularities`| Array of Strings | `['segment', 'word']`            | Specifies the granularity of timestamps. Can be `['segment']`, `['word']`, or both. Requires `response_format` to be `'verbose_json'`.                                     |
| `:temperature`            | Float            | `0.0`                            | A value between 0.0 and 1.0. Lower values are more deterministic. `0.0` is recommended for transcription accuracy.                                                      |
| `:prompt`                 | String           | `nil`                            | An optional prompt to guide the model's style or specify context/spellings (max 224 tokens).                                                                          |
| `:retries`                | Integer          | `3`                              | Number of times to retry a chunk if a recoverable API error (like rate limiting or timeout) occurs.                                                                     |
| `:retry_delay_sec`        | Integer          | `60`                             | Seconds to wait before retrying a failed API call for a chunk.                                                                                                          |
| `:api_timeout_sec`        | Integer          | `300` (5 minutes)                | Timeout in seconds for individual HTTP API calls to Groq for transcribing a chunk.                                                                                      |

## 4. Example Usage

Create a Ruby script (e.g., `run_transcriber.rb`) in your project root:

```ruby
# run_transcriber.rb

require 'logger'
require_relative 'lib/groq_transcriber' # Adjust path if groq_transcriber.rb is elsewhere

# --- Configuration ---
# Set the path to your audio file.
# It can be mp3, wav, m4a, flac, etc. FFmpeg must be able_to read it.
AUDIO_FILE_PATH = '/path/to/your/sample_audio.mp3' # !!! PLEASE UPDATE THIS PATH !!!

# --- Main Execution ---
def main
  unless File.exist?(AUDIO_FILE_PATH)
    puts "Error: Audio file not found at '#{AUDIO_FILE_PATH}'"
    puts "Please update the AUDIO_FILE_PATH variable in this script."
    return
  end

  # Optional: Create a custom logger
  custom_logger = Logger.new($stdout)
  custom_logger.level = Logger::DEBUG # Set to :INFO for less verbose output

  begin
    # Initialize the transcriber
    # Option 1: API key from ENV['GROQ_API_KEY'], default options
    # transcriber = Groq::Transcriber.new(logger: custom_logger)

    # Option 2: API key provided directly
    # transcriber = Groq::Transcriber.new(api_key: 'gsk_your_actual_key_here', logger: custom_logger)

    # Option 3: Custom default options (API key from ENV)
    transcriber = Groq::Transcriber.new(
      default_options: {
        model: 'whisper-large-v3', # Use a specific model
        language: 'en',
        chunk_length_sec: 300,     # 5-minute chunks
        overlap_sec: 10            # 10-second overlap
      },
      logger: custom_logger
    )

    puts "Starting transcription for: #{AUDIO_FILE_PATH}"

    # Run the transcription job
    # You can also override options here specifically for this job, e.g.:
    # prompt: "The speakers are discussing technical topics related to Ruby on Rails."
    result = transcriber.transcribe(
      file_path: AUDIO_FILE_PATH,
      output_dir_name: 'my_transcripts', # Custom output directory
      save_files: true,                  # Ensure files are saved
      job_options: {                     # Options specific to this run
        prompt: 'The main speaker is Dr. Anya Sharma, discussing quantum entanglement.'
        # temperature: 0.1 # Override temperature for this job
      }
    )

    puts "\n--- Transcription Complete! ---"
    puts "Final Text:"
    # puts result['text'] # Print the full text

    puts "\nFirst 200 characters of text:"
    puts "#{result['text'][0...200]}..."

    puts "\nNumber of segments: #{result['segments'].size}"
    puts "Number of words: #{result['words'].size}"

    if result['segments'].any?
      puts "\nFirst segment's text: #{result['segments'].first['text']}"
      puts "First segment's start: #{result['segments'].first['start']}s, end: #{result['segments'].first['end']}s"
    end

    puts "-------------------------------"
    puts "Full results, including timestamps, are saved in the 'my_transcripts' directory."

  rescue ArgumentError => e
    custom_logger.error("Configuration Error: #{e.message}")
  rescue RuntimeError => e
    custom_logger.error("Transcription Process Error: #{e.message}")
  rescue StandardError => e
    custom_logger.error("An Unexpected Error Occurred: #{e.message}")
    custom_logger.error(e.backtrace.join("\n"))
  end
end

# Run the main function if the script is executed directly
if __FILE__ == $PROGRAM_NAME
  main
end
```

### How to Run the Example:

1.  Save the example code above as `run_transcriber.rb` in your project root.
2.  **Crucially, update the `AUDIO_FILE_PATH` variable** in `run_transcriber.rb` to point to an actual audio file on your system.
3.  Ensure your `GROQ_API_KEY` is set as an environment variable, or modify the script to pass it directly to the constructor.
4.  Open your terminal, navigate to your project directory, and run:
    ```bash
    bundle exec ruby run_transcriber.rb
    ```
    (If not using Bundler: `ruby run_transcriber.rb`)

## 5. Output Files Explained

If `save_files: true` (the default) is used when calling `transcribe`, the following files will be generated in the specified `output_dir_name` (defaulting to `transcriptions/`):

The filenames will be in the format: `[original_audio_basename]_[timestamp]`.

*   **`your_audio_file_YYYYMMDD_HHMMSS.txt`**:
    A plain text file containing only the final, fully merged transcribed text.

*   **`your_audio_file_YYYYMMDD_HHMMSS_full.json`**:
    A JSON file containing the complete result hash, including the merged `text`, the array of `segments` (with their individual metadata and timestamps), and the array of `words` (with their individual timestamps). This is useful for detailed analysis or further processing.

*   **`your_audio_file_YYYYMMDD_HHMMSS_segments.json`**:
    A JSON file containing only the array of segment objects. Each segment includes its text, start/end times, and other metadata from the Groq API. This can be useful for creating subtitles or for applications that need to work with text segments.

This guide should provide a comprehensive overview of how to use the `Groq::Transcriber` class.
