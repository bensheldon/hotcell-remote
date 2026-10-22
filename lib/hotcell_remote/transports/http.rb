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
        # The service sends a newline while the cell works, so read_timeout bounds only each read, and this
        # deadline bounds the whole answer.
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout

        post(control ? CONTROL_PATH : WORK_PATH, line, inputs, timeout) do |response|
          case response.code
          when "200" then receive(response, outputs.map(&:to_io), deadline)
          when "401" then failed("invalid", "the service refused the request: #{response.body}")
          else failed("unavailable", "the service answered #{response.code}")
          end
        end
      rescue SystemCallError, IOError, SocketError, Timeout::Error, OpenSSL::SSL::SSLError => e
        failed("unavailable", e)
      end

      private

      def post(path, line, inputs, timeout)
        request = Net::HTTP::Post.new(URI.join(@uri, path))
        request[PROTOCOL_HEADER] = PROTOCOL.to_s
        request["Authorization"] = "#{SECRET_SCHEME} #{@secret}" if @secret
        form = [["request", line]] + inputs.each_with_index.map { |input, index| ["input#{index}", input.to_io, { filename: "input#{index}" }] }
        request.set_form(form, "multipart/form-data")

        Net::HTTP.start(@uri.host, @uri.port, use_ssl: @uri.scheme == "https", open_timeout: 5, read_timeout: timeout) do |http|
          result = nil
          http.request(request) { |response| result = yield(response) }
          result
        end
      end

      # Skips the keepalive newlines, then reads the response line, the outputs' sizes, and each output's bytes,
      # which it writes straight into the outputs.
      def receive(response, outputs, deadline)
        reader = Reader.new(outputs)
        response.read_body do |chunk|
          raise Timeout::Error, "the service did not answer in time" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

          reader << chunk
        end
        reader.response || failed("unavailable", "the service's answer ended early")
      rescue Timeout::Error => e
        failed("timeout", e)
      end

      def failed(code, detail)
        HotCell::Response.failed(HotCell::Failure.for(code, detail))
      end

      # Parses the answer as it arrives, so the outputs never have to fit in memory.
      class Reader
        def initialize(outputs)
          @outputs = outputs
          @buffer = +"".b
          @line = nil
          @sizes = nil
        end

        def <<(chunk)
          @buffer << chunk.b
          @buffer = @buffer.sub(/\A\n+/, "") if @line.nil?
          @line ||= take_line
          if @line && @sizes.nil? && (sizes = take_line)
            @sizes = sizes.strip.split(",").map { |size| Integer(size) }
          end
          write_outputs if @sizes
        end

        def response
          return nil unless @line && @sizes && @sizes.empty?

          HotCell::Response.parse(@line)
        end

        private

        def take_line
          index = @buffer.index("\n") or return nil
          @buffer.slice!(0..index)
        end

        def write_outputs
          loop do
            finish_output while @sizes.first&.zero?
            break if @sizes.empty? || @buffer.empty?

            bytes = @buffer.slice!(0, @sizes.first)
            @outputs.first.write(bytes)
            @sizes[0] -= bytes.bytesize
          end
        end

        def finish_output
          @sizes.shift
          @outputs.shift&.flush
        end
      end
    end
  end
end
