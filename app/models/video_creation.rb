class VideoCreation < ApplicationRecord
  belongs_to :user
  has_one_attached :file

  validates :title, presence: true
  validates :file, presence: true # Reverted to presence: true
  # validates :file, content_type: ['video/mp4', 'video/mpeg', 'video/quicktime', 'video/webm', 'video/x-msvideo', 'video/x-flv']
end
