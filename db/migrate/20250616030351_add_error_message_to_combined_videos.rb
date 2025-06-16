class AddErrorMessageToCombinedVideos < ActiveRecord::Migration[7.1]
  def change
    add_column :combined_videos, :error_message, :text
  end
end
