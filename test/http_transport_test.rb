# frozen_string_literal: true

require "test_helper"
require "hot_cell/remote/transports/http"

class HttpTransportTest < ActiveSupport::TestCase
  test "raises a transient failure when the service is unreachable" do
    HotCell.register "unreachable", dir: "/hotcell-remote/unreachable", transport: HotCell::Remote::Transports::Http.new("http://127.0.0.1:1")

    with_files do |input|
      error = assert_raises(HotCell::TransientFailure) { client("unreachable", "text.count").perform_in_hotcell(input, []) }
      assert_equal "unavailable", error.hot_cell_failure.code
    end
  end

  test "classifies malformed and incomplete replies as unavailable" do
    ok = HotCell::Response.ok(result: {}).to_line
    replies = [
      "not-json\n\n",
      "#{ok}-1\n",
      "#{ok}no-size\n",
      "#{ok}1,1\nab",
      "#{ok}\n",
      "#{ok}2\na",
      "#{ok}1\nab",
      "#{ok}#{'9' * 30}\n",
      "x" * (HotCell::MAX_RESPONSE_BYTES + 1),
      "#{ok}#{'1' * (HotCell::MAX_RESPONSE_BYTES + 1)}"
    ]

    replies.each do |body|
      with_http_server(reply: body) do |transport, cell|
        with_files do |input, output|
          response = transport.call(cell, HotCell::Request.new(op: "text.reverse", inputs: 1, outputs: 1).to_line,
                                    [HotCell::Input.new(input), HotCell::Output.new(output)])
          assert_equal "unavailable", response.failure&.code, body.byteslice(0, 80).inspect
        end
      end
    end
  end

  test "streams multiple outputs and preserves operation failures" do
    body = "#{HotCell::Response.ok(result: { count: 2 }).to_line}3,2\nabcde"
    with_http_server(reply: body) do |transport, cell|
      with_files do |_input, first, first_path|
        with_files do |_other, second, second_path|
          response = transport.call(cell, HotCell::Request.new(op: "example", outputs: 2).to_line,
                                    [HotCell::Output.new(first), HotCell::Output.new(second)])
          assert_equal({ count: 2 }, response.result)
          assert_equal %w[abc de], [File.read(first_path), File.read(second_path)]
        end
      end
    end

    failure = HotCell::Response.failed(HotCell::Failure.for("unreadable", "broken input"))
    body = "#{failure.to_line}\n"
    with_http_server(reply: body) do |transport, cell|
      response = transport.call(cell, HotCell::Request.new(op: "example").to_line, [])
      assert_equal "unreadable", response.failure.code
    end
  end

  test "reads fragmented keepalives, metadata, and output bytes" do
    body = "\n\n#{HotCell::Response.ok(result: { bytes: 3 }).to_line}3\nabc"
    reply = lambda do |socket|
      socket.write("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n")
      body.each_char { |byte| socket.write("1\r\n#{byte}\r\n") }
      socket.write("0\r\n\r\n")
    end
    with_http_server(reply:) do |transport, cell|
      with_files do |_input, output, path|
        response = transport.call(cell, HotCell::Request.new(op: "example", outputs: 1).to_line, [HotCell::Output.new(output)])
        assert_equal({ bytes: 3 }, response.result)
        assert_equal "abc", File.read(path)
      end
    end
  end

  test "bounds the whole response even when headers or a body chunk arrive slowly" do
    ["HTTP/1.1 200 OK\r\nX-Slow: ", "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n100\r\n"].each do |prefix|
      slow_reply = lambda do |socket|
        socket.write(prefix)
        30.times do
          sleep 0.03
          socket.write("x")
        end
      end
      with_http_server(reply: slow_reply, timeout: 0.15) do |transport, cell|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        response = transport.call(cell, HotCell::Request.new(op: "example").to_line, [])
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
        assert_equal "timeout", response.failure.code
        assert_operator elapsed, :<, 0.6
      end
    end
  end

  private

  def with_http_server(reply:, timeout: 2)
    server = TCPServer.new("127.0.0.1", 0)
    transport = HotCell::Remote::Transports::Http.new("http://127.0.0.1:#{server.addr[1]}")
    cell = HotCell::Cell.new("http-test", dir: "/unused", timeout:)
    socket = nil
    worker = Thread.new do
      socket = server.accept
      length = 0
      while (line = socket.gets) && line != "\r\n"
        length = line.split(":", 2).last.to_i if line.downcase.start_with?("content-length:")
      end
      socket.read(length)
      if reply.respond_to?(:call)
        reply.call(socket)
      else
        socket.write("HTTP/1.1 200 OK\r\nContent-Length: #{reply.bytesize}\r\n\r\n#{reply}")
      end
    rescue IOError, SystemCallError
      nil
    ensure
      socket&.close unless socket&.closed?
    end
    yield transport, cell
  ensure
    socket&.close unless socket&.closed?
    server&.close
    worker&.join
  end
end
