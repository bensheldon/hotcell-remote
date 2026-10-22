# frozen_string_literal: true

require "hot_cell/client"
require "hotcell_remote/version"

# Runs Hot Cell as a network service. An application registers its cells with HotcellRemote.register, and then
# uses Hot Cell's own clients and operations. Each request travels over HTTP to the service, whose gateway
# passes it to a Hot Cell. For development and test, the same requests can run in process, with no isolation.
module HotcellRemote
  class ConfigurationError < StandardError; end

  # The headers and paths of the HTTP API.
  SECRET_SCHEME = "Bearer"
  OUTPUT_SIZES_HEADER = "hotcell-remote-output-sizes"
  WORK_PATH = "/work"
  CONTROL_PATH = "/control"

  class << self
    # The service's URL. Every request goes there when it's set.
    attr_accessor :url

    # The shared secret that the service requires, if any.
    attr_accessor :secret

    # Whether requests may run in process, with no isolation, when there's no URL. The engine allows it only in
    # development and test.
    attr_accessor :inline

    # The directory of the application's operations, which load when requests first run in process.
    attr_accessor :operations_path

    # Requires every operation file under +path+, in sorted order, as a Hot Cell loads them.
    def load_operations(path)
      Dir[File.join(path, "**", "*.rb")].each { |file| require file }
    end

    # Registers a Hot Cell that the service runs, with the options that HotCell.register takes.
    def register(name, **)
      HotCell.register(name, dir: File.join("/hotcell-remote", name.to_s), transport: transport, **)
    end

    def transport
      if url.to_s.strip != ""
        require "hotcell_remote/transports/http"
        Transports::Http.new(url, secret: secret.to_s.strip.empty? ? nil : secret)
      elsif inline
        require "hotcell_remote/transports/inline"
        Transports::Inline.new(operations_path)
      else
        raise ConfigurationError, "HotcellRemote.url is not set; requests run in process only in development and test"
      end
    end
  end
end

require "hotcell_remote/engine" if defined?(Rails::Engine)
