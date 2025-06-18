FactoryBot.define do
  factory :video_creation do
    title { "Sample Video Title" }
    association :user

    after(:build) do |video_creation|
      # Ensure the directory exists (though the previous step should have created it)
      FileUtils.mkdir_p(Rails.root.join('spec', 'fixtures', 'files'))

      sample_file_path = Rails.root.join('spec', 'fixtures', 'files', 'sample_video.mp4')

      # The dummy file is already created in the previous bash command.
      # If for some reason it wasn't, this would create it.
      unless File.exist?(sample_file_path)
        File.open(sample_file_path, 'w') { |f| f.write("dummy video content") }
      end

      video_creation.file.attach(
        io: File.open(sample_file_path),
        filename: 'sample_video.mp4',
        content_type: 'video/mp4'
      )
    end
  end
end
