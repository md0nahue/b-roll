require 'rails_helper'

RSpec.describe CombinedVideo, type: :model do
  describe 'attributes' do
    it 'can be created with a status' do
      combined_video = create(:combined_video, status: 'processing')
      expect(combined_video.status).to eq('processing')
    end

    it 'can be created with an s3_url' do
      combined_video = create(:combined_video, s3_url: 'http://example.com/video.mp4')
      expect(combined_video.s3_url).to eq('http://example.com/video.mp4')
    end

    it 'can be created with an error_message' do
      combined_video = create(:combined_video, error_message: 'Something went wrong')
      expect(combined_video.error_message).to eq('Something went wrong')
    end

    it 'has a default status from the factory' do
      combined_video = create(:combined_video)
      expect(combined_video.status).to eq('pending')
    end

    it 'has a default s3_url from the factory' do
      combined_video = create(:combined_video)
      expect(combined_video.s3_url).to be_nil
    end

    it 'has a default error_message from the factory' do
      combined_video = create(:combined_video)
      expect(combined_video.error_message).to be_nil
    end

    it 'allows status to be updated' do
      combined_video = create(:combined_video)
      combined_video.update(status: 'completed')
      expect(combined_video.status).to eq('completed')
    end

    it 'allows s3_url to be updated' do
      combined_video = create(:combined_video)
      combined_video.update(s3_url: 'http://new-example.com/updated_video.mp4')
      expect(combined_video.s3_url).to eq('http://new-example.com/updated_video.mp4')
    end

    it 'allows error_message to be updated' do
      combined_video = create(:combined_video)
      combined_video.update(error_message: 'A new error occurred')
      expect(combined_video.error_message).to eq('A new error occurred')
    end
  end
end
