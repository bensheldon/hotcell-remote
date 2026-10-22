# frozen_string_literal: true

module HotcellRemote
  class Engine < ::Rails::Engine
    isolate_namespace HotcellRemote

    config.hotcell_remote = ActiveSupport::OrderedOptions.new
    config.hotcell_remote.url = ENV.fetch("HOTCELL_REMOTE_URL", nil)
    config.hotcell_remote.access_secret = ENV.fetch("HOTCELL_ACCESS_SECRET", nil)
    config.hotcell_remote.operations_path = nil

    # Class names to install in Active Storage, e.g. a transformer that calls the app's own operations.
    config.hotcell_remote.active_storage = ActiveSupport::OrderedOptions.new

    initializer "hotcell_remote.configure" do |app|
      HotcellRemote.url = app.config.hotcell_remote.url
      HotcellRemote.access_secret = app.config.hotcell_remote.access_secret
      HotcellRemote.inline = Rails.env.local?
      HotcellRemote.operations_path = app.config.hotcell_remote.operations_path || app.root.join("hotcell/operations")
    end

    # Active Storage sets these from config.active_storage in an after_initialize registered by its
    # "active_storage.configs" initializer, so this registers its own after that one.
    initializer "hotcell_remote.active_storage", after: "active_storage.configs" do |app|
      settings = app.config.hotcell_remote.active_storage

      config.after_initialize do
        ::ActiveStorage.variant_transformer = settings.variant_transformer.constantize if settings.variant_transformer
        ::ActiveStorage.analyzers = settings.analyzers.map(&:constantize) if settings.analyzers
        ::ActiveStorage.previewers = settings.previewers.map(&:constantize) if settings.previewers
      end
    end
  end
end
