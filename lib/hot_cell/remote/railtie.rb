# frozen_string_literal: true

module HotCell
  module Remote
    class Railtie < ::Rails::Railtie
      config.hotcell_remote = ActiveSupport::OrderedOptions.new
      config.hotcell_remote.url = ENV.fetch("HOTCELL_REMOTE_URL", nil)
      config.hotcell_remote.secret = ENV.fetch("HOTCELL_REMOTE_SECRET", nil)
      config.hotcell_remote.operations_path = nil

      # Before the application's initializers, which register its cells.
      initializer "hotcell_remote.configure", before: :load_config_initializers do |app|
        HotCell::Remote.url = app.config.hotcell_remote.url
        HotCell::Remote.secret = app.config.hotcell_remote.secret
        HotCell::Remote.inline = Rails.env.local?
        HotCell::Remote.operations_path = app.config.hotcell_remote.operations_path || app.root.join("hotcell/operations")
      end
    end
  end
end
