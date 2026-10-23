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

    config.active_storage.variant_processor = :disabled

    initializer "application.hotcell", after: "active_storage.configs" do
      config.after_initialize do
        ActiveStorage.variant_transformer = HotCellActiveStorage::Transformer
        ActiveStorage.analyzers = [HotCellActiveStorage::ImageAnalyzer]
        ActiveStorage.previewers = [HotCellActiveStorage::PdfPreviewer]
      end
    end

    config.active_storage.service = Rails.env.test? ? :test : :local
  end
end
