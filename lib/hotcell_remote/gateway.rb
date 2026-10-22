# frozen_string_literal: true

require "rack"
require "hot_cell/client"
require "hotcell_remote"

module HotcellRemote
  # The service's HTTP API. It passes each request to the local Hot Cell, unchanged: the request line and the
  # inputs from the application, and the response line and the outputs back. It never parses an input, and
  # the cell answers for everything else, including operations that don't exist and payloads that don't fit.
  #
  #   POST /work      a request for an operation
  #   POST /control   a describe or metrics request
  #   GET  /up        a health check, which needs no secret
  class Gateway
    def initialize(cell, secret: nil)
      @cell = cell
      @secret = secret.to_s.strip.empty? ? nil : secret
      @transport = HotCell::Transport::Socket.new
    end

    def call(env)
      request = ::Rack::Request.new(env)
      return [200, { "content-type" => "text/plain" }, ["ok"]] if request.get? && request.path_info == "/up"
      return [401, { "content-type" => "text/plain" }, ["unauthorized"]] unless authorized?(request)
      return [404, { "content-type" => "text/plain" }, ["not found"]] unless request.post?

      case request.path_info
      when WORK_PATH then work(request)
      when CONTROL_PATH then answer(@transport.call(@cell, line(request), [], socket: @cell.control_socket, timeout: @cell.control_timeout), [])
      else [404, { "content-type" => "text/plain" }, ["not found"]]
      end
    end

    private

    def authorized?(request)
      @secret.nil? || ::Rack::Utils.secure_compare(request.get_header("HTTP_AUTHORIZATION").to_s, "#{SECRET_SCHEME} #{@secret}")
    end

    def line(request)
      request.POST.fetch("request").to_s
    end

    def work(request)
      line = line(request)
      parsed = HotCell::Request.parse(line)
      uploads = Array.new(parsed.inputs) { |index| request.POST.fetch("input#{index}").fetch(:tempfile) }

      Dir.mktmpdir("hotcell-remote") do |dir|
        inputs = uploads.map { |upload| File.open(upload.path, "rb") }
        outputs = Array.new(parsed.outputs) { |index| File.open(File.join(dir, "output-#{index}"), "wb") }
        descriptors = inputs.map { |io| HotCell::Input.new(io) } + outputs.map { |io| HotCell::Output.new(io) }

        answer(@transport.call(@cell, line, descriptors), outputs.map(&:path))
      ensure
        (inputs.to_a + outputs.to_a).each(&:close)
      end
    rescue HotCell::MessageError, KeyError => e
      answer(HotCell::Response.failed(HotCell::Failure.for("invalid", e)), [])
    end

    # The response line, then each output's bytes. A failed request carries no outputs.
    def answer(response, output_paths)
      outputs = response.ok? ? output_paths.map { |path| File.binread(path) } : []
      headers = { "content-type" => "application/octet-stream", OUTPUT_SIZES_HEADER => outputs.map(&:bytesize).join(",") }

      [200, headers, [response.to_line, *outputs]]
    end
  end
end
