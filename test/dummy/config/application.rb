# frozen_string_literal: true

require "rails"
require "hot_cell/remote"

module Dummy
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.logger = Logger.new(nil)
    config.secret_key_base = "test"
    config.hotcell_remote.operations_path = File.expand_path("../../fixtures/operations", __dir__)
  end
end
