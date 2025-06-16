class CreateCombinedVideos < ActiveRecord::Migration[7.1]
  def change
    create_table :combined_videos do |t|
      t.string :s3_url
      t.string :status

      t.timestamps
    end
  end
end
