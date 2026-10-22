# frozen_string_literal: true

require "rack"
require "tmpdir"

module HotcellRemote
  # The HTTP interface to operations: POST /ops/<operation> with the input file as the body and the payload
  # as JSON in the Hotcell-Remote-Payload header. An operation that writes a file answers with those bytes and its
  # result in the Hotcell-Remote-Result header; one that doesn't answers with its result as JSON.
  #
  # With an access secret, every request but GET /up must send it as "Authorization: Bearer <secret>".
  #
  # The gateway only streams the body to disk; it never decodes it. Decoding happens in the executor.
  class Gateway
    MAX_INPUT_BYTES = 100 * 1024 * 1024
    PAYLOAD_HEADER = "Hotcell-Remote-Payload"
    RESULT_HEADER = "hotcell-remote-result"

    def initialize(executor:, access_secret: nil)
      @executor = executor
      @access_secret = access_secret.to_s.strip.empty? ? nil : access_secret
    end

    def call(env)
      request = ::Rack::Request.new(env)
      return [200, { "content-type" => "text/plain" }, ["ok"]] if request.get? && request.path_info == "/up"
      return error(401, "Unauthorized") unless authorized?(request)

      operation = request.path_info.delete_prefix("/ops/")
      return error(404, "Unknown operation #{operation}") unless request.post? && HotcellRemote.operations.key?(operation)

      payload = JSON.parse(request.get_header("HTTP_#{PAYLOAD_HEADER.upcase.tr('-', '_')}") || "{}")
      raise ArgumentError, "payload must be a JSON object" unless payload.is_a?(Hash)

      HotcellRemote.operations.fetch(operation).verify_payload!(payload)

      Dir.mktmpdir("hotcell_remote") do |dir|
        input = File.join(dir, "input")
        output = File.join(dir, "output")
        receive(request.body, input)
        File.write(output, "")

        result = @executor.call(operation, input, output, payload)
        if File.empty?(output)
          [200, { "content-type" => "application/json" }, [JSON.generate(result)]]
        else
          [200, { "content-type" => "application/octet-stream", RESULT_HEADER => JSON.generate(result, ascii_only: true) }, [File.binread(output)]]
        end
      end
    rescue JSON::ParserError, ArgumentError => e
      error(400, e.message)
    rescue PermanentError => e
      error(422, e.message)
    rescue TransientError => e
      error(503, e.message)
    end

    private

    def authorized?(request)
      @access_secret.nil? || ::Rack::Utils.secure_compare(request.get_header("HTTP_AUTHORIZATION").to_s, "Bearer #{@access_secret}")
    end

    def receive(body, path)
      File.open(path, "wb") do |file|
        while (chunk = body.read(64 * 1024))
          raise PermanentError, "input is larger than #{MAX_INPUT_BYTES} bytes" if file.pos + chunk.bytesize > MAX_INPUT_BYTES

          file.write(chunk)
        end
      end
    end

    def error(status, message)
      [status, { "content-type" => "application/json" }, [JSON.generate(error: message)]]
    end
  end
end
