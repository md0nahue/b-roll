ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup" # Set up gems listed in the Gemfile.

env = ENV['RAILS_ENV'] || 'development'

if env == 'production'
  require 'bootsnap/setup'
end