# frozen_string_literal: true

require "rack/mock_request"

module HotcellRemote
  module Transports
    # Calls a gateway in this process, through the same HTTP interface the remote service exposes.
    class Rack
      def initialize(app)
        @app = app
      end

      def perform(operation, input, payload)
        env = ::Rack::MockRequest.env_for("/ops/#{operation}", method: "POST", input: input.read.b,
                                                               "HTTP_#{Gateway::PAYLOAD_HEADER.upcase.tr('-', '_')}" => JSON.generate(payload, ascii_only: true))
        status, headers, body = @app.call(env)
        Transports.response(status, headers[Gateway::RESULT_HEADER], headers["content-type"], body.to_a.join)
      end
    end
  end
end
