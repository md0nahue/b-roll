require 'rails_helper'

RSpec.describe VideoCreation, type: :model do
  describe 'validations' do
    let(:user) { create(:user) } # Helper to get a valid user

    it 'is valid with a title, a file, and a user' do
      # The factory by default creates a valid video_creation with a file
      video_creation = build(:video_creation, user: user)
      expect(video_creation).to be_valid
    end

    it 'is invalid without a title' do
      video_creation = build(:video_creation, title: nil, user: user)
      expect(video_creation).not_to be_valid
      expect(video_creation.errors[:title]).to include("can't be blank")
    end

    it 'is invalid without a file' do
      # Build a video_creation without attaching a file
      video_creation = build(:video_creation, user: user)
      video_creation.file.detach # Ensure no file is attached
      expect(video_creation).not_to be_valid
      # Default error message for presence might be "can't be blank" or specific to Active Storage
      # For Active Storage, the actual validation is on the blob if `presence: true` is set on the association.
      # If the model has `validates :file, presence: true` directly, then errors[:file] will have "can't be blank".
      # Let's assume `validates :file, presence: true` is in the model.
      expect(video_creation.errors[:file]).to include("can't be blank")
    end

    it 'is invalid without a user' do
      video_creation = build(:video_creation, user: nil)
      # Detach the file that the factory attaches by default, to isolate the user validation
      # Re-attaching a file because the factory might require it for other validations or callbacks
      # A bit complex here: the factory attaches a file. If user is nil, it might still be valid
      # if file presence is the only other major validation.
      # Let's build it without the default file attachment for this specific test.
      video_creation_no_file_by_default = VideoCreation.new(title: "Test Title", user: nil)
      expect(video_creation_no_file_by_default).not_to be_valid
      expect(video_creation_no_file_by_default.errors[:user]).to include("must exist") # Devise/ActiveRecord error for belongs_to
    end
  end

  describe 'associations' do
    it { should belong_to(:user) }
  end

  describe 'file attachment (Active Storage)' do
    # Uses shoulda-matchers for Active Storage
    it { should have_one_attached(:file) }

    it 'actually has the file attached when created with one' do
      video_creation = create(:video_creation) # Factory attaches a file by default
      expect(video_creation.file).to be_attached
    end
  end
end
