# frozen_string_literal: true

require "json"
require "hotcell_remote/version"

# Runs operations on untrusted files in a separate service, whose gateway hands each request to a Hot Cell.
# For development and test, the same gateway can run in process, with no isolation.
module HotcellRemote
  class Error < StandardError; end

  # Retrying won't help: the input can't be processed or the request is wrong.
  class PermanentError < Error; end

  # Retrying may help: the service is busy, restarting, or unreachable.
  class TransientError < Error; end

  class UnreadableInput < PermanentError; end
  class ConfigurationError < Error; end

  Response = Data.define(:result, :output)

  class << self
    # The gateway's URL. Every call goes there when it's set.
    attr_accessor :url

    # Whether operations may run in process, with no isolation, when there's no URL. The engine allows it
    # only in development and test.
    attr_accessor :inline

    # The directory of operation files, which load when operations first run in process.
    attr_accessor :operations_path

    # The shared secret that the remote gateway requires, if any.
    attr_accessor :access_secret

    def operations
      @_operations ||= {}
    end

    # Calls the block with each operation class, now and as more are defined.
    def on_register(&block)
      registration_callbacks << block
      operations.each_value(&block)
    end

    def register(operation_class)
      operations[operation_class.operation] = operation_class
      registration_callbacks.each { |callback| callback.call(operation_class) }
    end

    # Requires every operation file under +path+, in sorted order, as a Hot Cell loads them.
    def load_operations(path)
      Dir[File.join(path, "**", "*.rb")].each { |file| require file }
    end

    # Runs +operation+ on +input+ (an IO) and returns a Response: the operation's result Hash and the bytes
    # it wrote, or nil when it wrote none.
    def perform(operation, input, **payload)
      transport.perform(operation, input, payload)
    end

    def transport=(transport)
      @_transport = transport
    end

    def registration_callbacks
      @_registration_callbacks ||= []
    end

    def transport
      @_transport ||= if url.to_s.strip != ""
                        Transports::Http.new(url, access_secret: access_secret.to_s.strip.empty? ? nil : access_secret)
                      elsif inline
                        load_operations(operations_path) if operations_path
                        Transports::Rack.new(Gateway.new(executor: Executors::Inline.new))
                      else
                        raise ConfigurationError, "HotcellRemote.url is not set; operations run in process only in development and test"
                      end
    end
  end
end

require "hotcell_remote/operation"
require "hotcell_remote/gateway"
require "hotcell_remote/executors/inline"
require "hotcell_remote/transports"
require "hotcell_remote/transports/rack"
require "hotcell_remote/transports/http"
require "hotcell_remote/engine" if defined?(Rails::Engine)
