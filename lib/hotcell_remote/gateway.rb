# frozen_string_literal: true

require "fileutils"
require "rack"
require "tmpdir"
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
  #
  # A relayed request always answers 200, and Hot Cell's response line says how it went. That lets the gateway
  # send its headers at once, and then a newline every +keepalive+ seconds while the cell works, so that a
  # router that times out a quiet response, such as Heroku's after 30 seconds, waits for the cell's answer.
  class Gateway
    KEEPALIVE = 15

    def initialize(cell, secret: nil, keepalive: KEEPALIVE)
      @cell = cell
      @secret = secret.to_s.strip.empty? ? nil : secret
      @keepalive = keepalive
      @transport = HotCell::Transport::Socket.new
    end

    def call(env)
      request = ::Rack::Request.new(env)
      return [200, { "content-type" => "text/plain" }, ["ok"]] if request.get? && request.path_info == "/up"
      return [401, { "content-type" => "text/plain" }, ["unauthorized"]] unless authorized?(request)
      return [404, { "content-type" => "text/plain" }, ["not found"]] unless request.post?

      case request.path_info
      when WORK_PATH then work(request)
      when CONTROL_PATH then control(request)
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

    def control(request)
      line = line(request)
      answer(Answer.new(@keepalive) { [@transport.call(@cell, line, [], socket: @cell.control_socket, timeout: @cell.control_timeout), []] })
    end

    def work(request)
      line = line(request)
      parsed = HotCell::Request.parse(line)
      uploads = Array.new(parsed.inputs) { |index| request.POST.fetch("input#{index}").fetch(:tempfile) }
      dir = Dir.mktmpdir("hotcell-remote")
      output_paths = Array.new(parsed.outputs) { |index| File.join(dir, "output-#{index}") }

      answer(Answer.new(@keepalive, cleanup: dir) { [relay(line, uploads, output_paths), output_paths] })
    rescue HotCell::MessageError, KeyError => e
      answer(Answer.new(@keepalive) { [HotCell::Response.failed(HotCell::Failure.for("invalid", e)), []] })
    end

    def relay(line, uploads, output_paths)
      inputs = uploads.map { |upload| File.open(upload.path, "rb") }
      outputs = output_paths.map { |path| File.open(path, "wb") }
      descriptors = inputs.map { |io| HotCell::Input.new(io) } + outputs.map { |io| HotCell::Output.new(io) }

      @transport.call(@cell, line, descriptors)
    ensure
      (inputs.to_a + outputs.to_a).each(&:close)
    end

    def answer(body)
      [200, { "content-type" => "application/octet-stream" }, body]
    end

    # The response body: newlines while the cell works, then Hot Cell's response line, a line of the outputs'
    # sizes, and the outputs' bytes. A failed request carries no outputs.
    class Answer
      CHUNK = 64 * 1024

      def initialize(keepalive, cleanup: nil, &work)
        @keepalive = keepalive
        @cleanup = cleanup
        @work = work
      end

      def each
        worker = Thread.new(&@work)
        yield "\n" until worker.join(@keepalive)
        response, output_paths = worker.value
        output_paths = [] unless response.ok?

        yield response.to_line
        yield "#{output_paths.map { |path| File.size(path) }.join(',')}\n"
        output_paths.each do |path|
          File.open(path, "rb") { |file| while (chunk = file.read(CHUNK)) do yield chunk end }
        end
      end

      def close
        FileUtils.rm_rf(@cleanup) if @cleanup
      end
    end
  end
end
