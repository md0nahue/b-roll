FactoryBot.define do
  factory :combined_video do
    status { "pending" }
    s3_url { nil }
    error_message { nil }
  end
end
