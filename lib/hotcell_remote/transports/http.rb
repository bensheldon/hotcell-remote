# frozen_string_literal: true

require "net/http"

module HotcellRemote
  module Transports
    class Http
      TRANSIENT_ERRORS = [IOError, SystemCallError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError].freeze

      def initialize(url, access_secret: nil, timeout: 90)
        @uri = URI(url)
        @access_secret = access_secret
        @timeout = timeout
      end

      def perform(operation, input, payload)
        request = Net::HTTP::Post.new(URI.join(@uri, "/ops/#{operation}"))
        request[Gateway::PAYLOAD_HEADER] = JSON.generate(payload, ascii_only: true)
        request["Content-Type"] = "application/octet-stream"
        request["Authorization"] = "Bearer #{@access_secret}" if @access_secret
        request.body = input.read

        response = Net::HTTP.start(@uri.host, @uri.port, use_ssl: @uri.scheme == "https", open_timeout: 5, read_timeout: @timeout) do |http|
          http.request(request)
        end
        Transports.response(response.code.to_i, response[Gateway::RESULT_HEADER], response.content_type, response.body)
      rescue *TRANSIENT_ERRORS => e
        raise TransientError, "#{e.class}: #{e.message}"
      end
    end
  end
end
