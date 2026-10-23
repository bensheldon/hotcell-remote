# frozen_string_literal: true

require "net/http"
require "timeout"

module HotCell
  module Remote
    module Transports
      # A Hot Cell transport that sends each request to the service over HTTP: the request line and the inputs'
      # bytes go up, and the response line and the outputs' bytes come back. Hot Cell's client does everything
      # else, as it does with its own socket transport.
      class Http
        class DeadlineExceeded < Timeout::Error; end

        def initialize(url, secret: nil)
          @uri = URI(url)
          @secret = secret
        end

        def call(cell, line, descriptors, socket: cell.work_socket, timeout: cell.timeout)
          control = socket == cell.control_socket
          inputs, outputs = descriptors.partition { |descriptor| descriptor.is_a?(HotCell::Input) }
          Timeout.timeout(timeout, DeadlineExceeded) do
            post(control ? CONTROL_PATH : WORK_PATH, line, inputs, timeout) do |response|
              response.read_body { nil } unless response.code == "200"
              case response.code
              when "200" then receive(response, outputs.map(&:to_io))
              when "401" then failed("invalid", "the service refused the request")
              else failed("unavailable", "the service answered #{response.code}")
              end
            end
          end
        rescue Timeout::Error => e
          failed("timeout", e)
        rescue HotCell::MessageError, Net::HTTPBadResponse, SystemCallError, IOError, SocketError, OpenSSL::SSL::SSLError => e
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
            http.max_retries = 0
            result = nil
            http.request(request) { |response| result = yield(response) }
            result
          end
        end

        # Skips the keepalive newlines, then reads the response line, the outputs' sizes, and each output's bytes,
        # which it writes straight into the outputs.
        def receive(response, outputs)
          reader = Reader.new(outputs)
          response.read_body { |chunk| reader << chunk }
          reader.response
        end

        def failed(code, detail)
          HotCell::Response.failed(HotCell::Failure.for(code, detail))
        end

        # Parses the answer as it arrives, so the outputs never have to fit in memory.
        class Reader
          def initialize(outputs)
            @outputs = outputs
            @buffer = +"".b
            @response = nil
            @sizes = nil
          end

          def <<(chunk)
            @buffer << chunk.b
            unless @response
              @buffer.sub!(/\A\n+/, "")
              line = take_line
              return unless line

              @response = HotCell::Response.parse(line.force_encoding(Encoding::UTF_8))
            end
            if @sizes.nil?
              line = take_line
              return unless line

              read_sizes(line.chomp)
            end
            write_outputs
            raise HotCell::MessageError, "bytes follow the service's answer" unless @buffer.empty?
          end

          def response
            raise HotCell::MessageError, "the service's answer ended early" unless @response && @sizes == []

            @response
          end

          private

          def take_line
            index = @buffer.index("\n")
            raise HotCell::MessageError, "the service's response line is too long" if (index ? index + 1 : @buffer.bytesize) > HotCell::MAX_RESPONSE_BYTES

            @buffer.slice!(0..index) if index
          end

          def read_sizes(line)
            raise HotCell::MessageError, "invalid output sizes" unless line.empty? || /\A[0-9]+(?:,[0-9]+)*\z/.match?(line)

            parts = line.empty? ? [] : line.split(",")
            raise HotCell::MessageError, "output sizes exceed the protocol bounds" if parts.size > HotCell::MAX_DESCRIPTORS || parts.any? { |size| size.size > 19 }

            sizes = parts.map { |size| Integer(size, 10) }
            expected = @response.ok? ? @outputs.size : 0
            raise HotCell::MessageError, "output sizes do not match the request" unless sizes.size == expected && sizes.all? { |size| size <= (2**63) - 1 }

            @sizes = sizes
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
            @outputs.shift.flush
          end
        end
      end
    end
  end
end
