# frozen_string_literal: true

require "net/http"

module HotcellRemote
  module Transports
    # A Hot Cell transport that sends each request to the service over HTTP: the request line and the inputs'
    # bytes go up, and the response line and the outputs' bytes come back. Hot Cell's client does everything
    # else, as it does with its own socket transport.
    class Http
      def initialize(url, secret: nil)
        @uri = URI(url)
        @secret = secret
      end

      def call(cell, line, descriptors, socket: cell.work_socket, timeout: cell.timeout)
        control = socket == cell.control_socket
        inputs, outputs = descriptors.partition { |descriptor| descriptor.is_a?(HotCell::Input) }

        response = post(control ? CONTROL_PATH : WORK_PATH, line, inputs, timeout)
        return failed("invalid", "the service refused the request: #{response.body}") if response.code == "401"
        return failed("unavailable", "the service answered #{response.code}") unless response.code == "200"

        receive(response, outputs)
      rescue SystemCallError, IOError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError => e
        failed("unavailable", e)
      end

      private

      def post(path, line, inputs, timeout)
        request = Net::HTTP::Post.new(URI.join(@uri, path))
        request["Authorization"] = "#{SECRET_SCHEME} #{@secret}" if @secret
        form = [["request", line]] + inputs.each_with_index.map { |input, index| ["input#{index}", input.to_io, { filename: "input#{index}" }] }
        request.set_form(form, "multipart/form-data")

        Net::HTTP.start(@uri.host, @uri.port, use_ssl: @uri.scheme == "https", open_timeout: 5, read_timeout: timeout) do |http|
          http.request(request)
        end
      end

      # The body is the response line, then each output's bytes, whose sizes are in a header.
      def receive(response, outputs)
        body = response.body.b
        line_end = body.index("\n") or return failed("unavailable", "the service's answer has no response line")
        sizes = response[OUTPUT_SIZES_HEADER].to_s.split(",").map { |size| Integer(size) }

        offset = line_end + 1
        outputs.zip(sizes).each do |output, size|
          output.to_io.write(body.byteslice(offset, size.to_i))
          output.to_io.flush
          offset += size.to_i
        end

        HotCell::Response.parse(body.byteslice(0, line_end + 1))
      end

      def failed(code, detail)
        HotCell::Response.failed(HotCell::Failure.for(code, detail))
      end
    end
  end
end
