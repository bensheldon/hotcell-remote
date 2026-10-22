# frozen_string_literal: true

require_relative "boot"

require "rails"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "active_job/railtie"

Bundler.require(*Rails.groups)

module ExampleApp
  class Application < Rails::Application
    config.load_defaults 8.1
    config.autoload_lib(ignore: %w[tasks])

    # The application doesn't process images itself; config/initializers/active_storage.rb routes Active Storage
    # through the service instead.
    config.active_storage.variant_processor = :disabled
    config.active_storage.service = Rails.env.test? ? :test : :local
  end
end
