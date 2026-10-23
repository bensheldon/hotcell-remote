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

    initializer "application.hotcell", after: "active_storage.configs" do
      config.after_initialize { HotCellClients.configure_active_storage }
    end

    config.active_storage.service = Rails.env.test? ? :test : :local
  end
end
